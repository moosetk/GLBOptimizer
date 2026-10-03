import { existsSync } from 'node:fs';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import sharp from 'sharp';
import { KHRTextureBasisu } from '@gltf-transform/extensions';
import {
  compressTexture,
  dedup,
  draco,
  instance,
  meshopt,
  prune,
  resample,
  simplify,
  sparse,
  textureCompress,
  weld,
} from '@gltf-transform/functions';
import { MeshoptEncoder, MeshoptSimplifier } from 'meshoptimizer';
import { createIO, extensionNames } from './lib/io.mjs';
import { countTriangles } from './lib/geometry.mjs';
import { fail, progress, captureConsole } from './lib/log.mjs';
import { pathToFileURL } from 'node:url';
import { stat } from 'node:fs/promises';
import { readJob, samePath } from './lib/job.mjs';

const execFileAsync = promisify(execFile);

const DATA_SLOTS = /^(normalTexture|occlusionTexture|metallicRoughnessTexture|emissiveTexture)$/;

export async function optimizeFile(job) {
  captureConsole();
  const started = Date.now();
  if (samePath(job.input, job.output)) {
    throw new Error('输出路径与源文件相同，已取消以免覆盖原文件。');
  }

  progress('正在读取模型', 0.05);
  const io = await createIO();
  const document = await io.read(job.input);
  progress('已读取模型，开始整理数据', 0.15);

  // Apple's Preview / Quick Look importer only reads core glTF: no compressed geometry,
  // quantized or sparse accessors, GPU instancing, or WebP/KTX2 images.
  const apple = job.compatibility === 'apple';

  const transforms = [];
  if (job.dedup !== false) transforms.push(dedup());
  if (job.instance !== false && !apple) transforms.push(instance());
  if (job.prune !== false) transforms.push(prune());
  if (job.weld !== false || job.simplify) transforms.push(weld());
  if (job.resample !== false) transforms.push(resample());

  if (transforms.length > 0) {
    progress('正在去重、焊接顶点并清理未使用数据', 0.28);
    await document.transform(...transforms);
  }

  if (job.simplify) {
    progress('正在简化网格', 0.4);
    await MeshoptSimplifier.ready;
    await document.transform(
      simplify({
        simplifier: MeshoptSimplifier,
        ratio: clamp(job.simplifyRatio ?? 0.5, 0, 1),
        error: clamp(job.simplifyError ?? 0.01, 0, 1),
        lockBorder: job.simplifyLockBorder !== false,
      }),
    );
  }

  if (job.sparse !== false && !apple) {
    await document.transform(sparse());
  }

  const textureJob = job.texture ?? {};
  if (document.getRoot().listTextures().length > 0 && apple) {
    await compressTexturesForApple(document, textureJob);
  } else if (document.getRoot().listTextures().length > 0 && textureJob.format !== 'skip') {
    await compressTextures(document, textureJob);
  } else {
    progress('没有需要处理的纹理', 0.62);
  }

  if (job.prune !== false) {
    await document.transform(prune());
  }

  const triangles = countTriangles(document);
  progress(apple ? '正在写入 macOS 兼容文件' : '正在压缩几何并写入文件', 0.82);
  if (!apple) await applyGeometryCompression(document, job);
  await io.write(job.output, document);

  const [inputStat, outputStat] = await Promise.all([stat(job.input), stat(job.output)]);
  const warnings = [];
  if (textureJob.format === 'ktx2') {
    warnings.push('KTX2 纹理需要查看器支持 KHR_texture_basisu。');
  }
  progress('优化完成', 1);
  return {
    type: 'result',
    output: job.output,
    inputBytes: inputStat.size,
    outputBytes: outputStat.size,
    elapsedMs: Date.now() - started,
    triangles,
    extensions: extensionNames(document),
    warnings,
  };
}

async function compressTextures(document, textureJob) {
  const format = textureJob.format ?? 'webp';
  const maxSize = Number(textureJob.maxSize ?? 0);
  const resize = maxSize > 0 ? [maxSize, maxSize] : undefined;
  const quality = Number.isFinite(textureJob.quality) ? textureJob.quality : 80;

  if (format === 'ktx2') {
    progress('正在缩放纹理，准备转成 KTX2', 0.5);
    const pngOptions = {
      encoder: sharp,
      targetFormat: 'png',
      limitInputPixels: false,
    };
    if (resize) pngOptions.resize = resize;
    await document.transform(textureCompress(pngOptions));
    progress('正在用 toktx 压缩纹理', 0.68);
    await encodeKTX2(document);
    document.disposeExtension('EXT_texture_webp');
    return;
  }

  progress(format === 'keep' ? '正在优化纹理' : `正在把纹理转为 ${format}`, 0.55);
  const options = {
    encoder: sharp,
    limitInputPixels: false,
  };
  if (resize) options.resize = resize;
  if (format === 'jpeg') {
    await document.transform(
      textureCompress({
        ...options,
        targetFormat: 'jpeg',
        quality,
        slots: /^baseColorTexture$/,
      }),
      textureCompress({
        ...options,
        targetFormat: 'webp',
        quality: Math.min(100, quality + 10),
        slots: DATA_SLOTS,
      }),
    );
    return;
  }
  if (format !== 'keep') {
    options.targetFormat = format;
    options.quality = quality;
  }
  await document.transform(textureCompress(options));
}

async function compressTexturesForApple(document, textureJob) {
  const maxSize = Number(textureJob.maxSize ?? 0);
  const quality = Number.isFinite(textureJob.quality) ? textureJob.quality : 85;
  const textures = document.getRoot().listTextures();
  for (let index = 0; index < textures.length; index += 1) {
    const texture = textures[index];
    const mime = texture.getMimeType();
    if (mime === 'image/ktx2') {
      throw new Error('源文件里有 KTX2 纹理，macOS 兼容模式无法把它转回 JPEG/PNG。');
    }
    const targetFormat = needsAlpha(document, texture) ? 'png' : 'jpeg';
    progress(`正在把第 ${index + 1}/${textures.length} 张纹理转为 ${targetFormat.toUpperCase()}`, 0.5 + (0.25 * index) / textures.length);
    const options = { encoder: sharp, targetFormat, quality, limitInputPixels: false };
    if (maxSize > 0) options.resize = [maxSize, maxSize];
    await compressTexture(texture, options);
  }
  document.disposeExtension('EXT_texture_webp');
  document.disposeExtension('EXT_texture_avif');
}

function needsAlpha(document, texture) {
  for (const material of document.getRoot().listMaterials()) {
    if (material.getBaseColorTexture() === texture && material.getAlphaMode() !== 'OPAQUE') {
      return true;
    }
  }
  return false;
}

async function encodeKTX2(document) {
  const toktx = findExecutable('toktx');
  if (!toktx) {
    throw new Error('未找到 toktx。KTX2 需要先安装 KTX-Software：brew install ktx-software');
  }
  const basisu = document.createExtension(KHRTextureBasisu);
  basisu.setRequired(true);
  const directory = await mkdtemp(join(tmpdir(), 'glbopt-ktx-'));
  try {
    const textures = document.getRoot().listTextures();
    for (let index = 0; index < textures.length; index += 1) {
      const texture = textures[index];
      const image = texture.getImage();
      if (!image) continue;
      const input = join(directory, `in-${index}${imageExtension(texture.getMimeType())}`);
      const output = join(directory, `out-${index}.ktx2`);
      await writeFile(input, image);
      const dataTexture = usesDataSlot(document, texture);
      const args = dataTexture
        ? ['--t2', '--encode', 'uastc', '--uastc_quality', '2', '--zcmp', '18', output, input]
        : ['--t2', '--encode', 'etc1s', '--clevel', '2', '--qlevel', '128', output, input];
      try {
        await execFileAsync(toktx, args);
      } catch (error) {
        const stderr = error.stderr?.toString?.() ?? error.message;
        throw new Error(`toktx 压缩纹理失败：${stderr}`);
      }
      texture.setImage(new Uint8Array(await readFile(output))).setMimeType('image/ktx2');
    }
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

function usesDataSlot(document, texture) {
  for (const material of document.getRoot().listMaterials()) {
    const slots = [
      material.getNormalTexture(),
      material.getOcclusionTexture(),
      material.getMetallicRoughnessTexture(),
      material.getEmissiveTexture(),
    ];
    if (slots.some((slot) => slot === texture)) return true;
  }
  return false;
}

function imageExtension(mime) {
  if (mime === 'image/jpeg') return '.jpg';
  if (mime === 'image/webp') return '.webp';
  return '.png';
}

async function applyGeometryCompression(document, job) {
  const mode = job.geometry ?? 'meshopt';
  if (mode === 'none') return;
  if (mode === 'draco') {
    await document.transform(
      draco({
        method: 'edgebreaker',
        encodeSpeed: job.dracoEncodeSpeed ?? 5,
        quantizePosition: job.dracoPositionBits ?? 14,
        quantizeNormal: job.dracoNormalBits ?? 10,
        quantizeTexcoord: job.dracoTexcoordBits ?? 12,
      }),
    );
    return;
  }
  await document.transform(
    meshopt({
      encoder: MeshoptEncoder,
      level: job.meshoptLevel === 'high' ? 'high' : 'medium',
    }),
  );
}

function findExecutable(name) {
  const paths = (process.env.PATH || '').split(':').filter(Boolean);
  for (const directory of paths) {
    const candidate = join(directory, name);
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

async function main() {
  const jobPath = process.argv[2];
  if (!jobPath) {
    throw new Error('用法：node optimize.mjs <job.json>');
  }
  const job = await readJob(jobPath);
  const result = await optimizeFile(job);
  const { emit } = await import('./lib/log.mjs');
  emit(result);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    fail(error);
    process.exitCode = 1;
  });
}
