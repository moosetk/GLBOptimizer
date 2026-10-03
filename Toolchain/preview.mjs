import { stat } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import sharp from 'sharp';
import { compressTexture, dequantize, normals, simplify, weld } from '@gltf-transform/functions';
import { MeshoptSimplifier } from 'meshoptimizer';
import { createIO, extensionNames } from './lib/io.mjs';
import { countTriangles } from './lib/geometry.mjs';
import { captureConsole, emit, fail, progress } from './lib/log.mjs';
import { readJob, samePath } from './lib/job.mjs';

// The app renders previews with SceneKit, which only understands plain float/int
// accessors and PNG/JPEG images, so every compression extension is decoded here.
const DECODED_EXTENSIONS = [
  'KHR_draco_mesh_compression',
  'EXT_meshopt_compression',
  'KHR_mesh_quantization',
  'EXT_texture_webp',
  'EXT_texture_avif',
];

export async function previewFile(job) {
  captureConsole();
  const started = Date.now();
  if (samePath(job.input, job.output)) {
    throw new Error('预览文件路径与源文件相同。');
  }
  const maxTriangles = Number(job.maxTriangles ?? 2_000_000);
  const maxTextureSize = Number(job.maxTextureSize ?? 2048);

  progress('正在读取模型', 0.1);
  const io = await createIO();
  const document = await io.read(job.input);
  const extensions = extensionNames(document);
  const sourceTriangles = countTriangles(document);

  await document.transform(dequantize(), normals({ overwrite: false }));

  let simplified = false;
  if (maxTriangles > 0 && sourceTriangles > maxTriangles) {
    progress('模型面数较多，正在生成简化预览', 0.4);
    await MeshoptSimplifier.ready;
    await document.transform(
      weld(),
      simplify({ simplifier: MeshoptSimplifier, ratio: maxTriangles / sourceTriangles, error: 0.02 }),
    );
    simplified = true;
  }

  progress('正在准备纹理', 0.7);
  for (const texture of document.getRoot().listTextures()) {
    const mime = texture.getMimeType();
    if (mime === 'image/ktx2') continue;
    const size = texture.getSize();
    const oversized = size && Math.max(size[0], size[1]) > maxTextureSize;
    if (mime !== 'image/webp' && mime !== 'image/avif' && !oversized) continue;
    const options = {
      encoder: sharp,
      targetFormat: mime === 'image/jpeg' ? 'jpeg' : 'png',
      quality: 90,
      limitInputPixels: false,
    };
    if (oversized) options.resize = [maxTextureSize, maxTextureSize];
    await compressTexture(texture, options);
  }

  for (const accessor of document.getRoot().listAccessors()) {
    accessor.setSparse(false);
  }
  for (const extension of document.getRoot().listExtensionsUsed()) {
    if (DECODED_EXTENSIONS.includes(extension.extensionName)) extension.dispose();
  }

  progress('正在写入预览', 0.9);
  await io.write(job.output, document);
  const [inputStat, outputStat] = await Promise.all([stat(job.input), stat(job.output)]);
  return {
    type: 'result',
    output: job.output,
    inputBytes: inputStat.size,
    outputBytes: outputStat.size,
    elapsedMs: Date.now() - started,
    triangles: countTriangles(document),
    sourceTriangles,
    extensions,
    simplified,
  };
}

async function main() {
  const jobPath = process.argv[2];
  if (!jobPath) {
    throw new Error('用法：node preview.mjs <job.json>');
  }
  emit(await previewFile(await readJob(jobPath)));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    fail(error);
    process.exitCode = 1;
  });
}
