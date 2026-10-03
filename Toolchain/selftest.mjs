import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import sharp from 'sharp';
import { Document } from '@gltf-transform/core';
import { createIO } from './lib/io.mjs';
import { convertFile } from './convert.mjs';
import { optimizeFile } from './optimize.mjs';
import { previewFile } from './preview.mjs';

async function readGLBJSON(path) {
  const bytes = await readFile(path);
  const length = bytes.readUInt32LE(12);
  return JSON.parse(bytes.subarray(20, 20 + length).toString('utf8'));
}

const failures = [];

function assert(condition, message) {
  if (!condition) failures.push(message);
}

async function makeSource(directory) {
  const io = await createIO();
  const document = new Document();
  const buffer = document.createBuffer();
  const width = 8;
  const height = 8;
  const positions = [];
  const indices = [];
  for (let y = 0; y <= height; y += 1) {
    for (let x = 0; x <= width; x += 1) {
      positions.push(x * 0.1, y * 0.1, 0);
    }
  }
  const stride = width + 1;
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const a = y * stride + x;
      indices.push(a, a + 1, a + stride, a + 1, a + stride + 1, a + stride);
    }
  }
  const position = document.createAccessor().setType('VEC3').setArray(new Float32Array(positions)).setBuffer(buffer);
  const index = document.createAccessor().setType('SCALAR').setArray(new Uint32Array(indices)).setBuffer(buffer);
  const prim = document.createPrimitive().setAttribute('POSITION', position).setIndices(index);
  const mesh = document.createMesh('grid').addPrimitive(prim);
  const node = document.createNode('grid').setTranslation([10, 0, 0]).setMesh(mesh);
  const scene = document.createScene('main').addChild(node);
  document.getRoot().setDefaultScene(scene);

  const raw = Buffer.alloc(256 * 128 * 3);
  for (let y = 0; y < 128; y += 1) {
    for (let x = 0; x < 256; x += 1) {
      const index = (y * 256 + x) * 3;
      raw[index] = x % 256;
      raw[index + 1] = (y * 2) % 256;
      raw[index + 2] = (x + y * 3) % 256;
    }
  }
  const png = await sharp(raw, { raw: { width: 256, height: 128, channels: 3 } }).png().toBuffer();
  const texture = document.createTexture('color').setImage(new Uint8Array(png)).setMimeType('image/png');
  const material = document.createMaterial('color').setBaseColorTexture(texture);
  prim.setMaterial(material);

  const input = join(directory, 'source.glb');
  await io.write(input, document);
  return input;
}

async function main() {
  const directory = await mkdtemp(join(tmpdir(), 'glbopt-selftest-'));
  try {
    const input = await makeSource(directory);
    const optimized = join(directory, 'optimized.glb');
    const result = await optimizeFile({
      input,
      output: optimized,
      geometry: 'meshopt',
      meshoptLevel: 'medium',
      texture: { format: 'webp', maxSize: 64, quality: 75 },
      simplify: false,
      weld: true,
      dedup: true,
      prune: true,
      resample: true,
      instance: true,
      sparse: true,
    });
    assert(result.outputBytes > 0, '优化结果为空');
    assert(result.outputBytes < result.inputBytes, `优化后没有变小：${result.inputBytes} -> ${result.outputBytes}`);
    const io = await createIO();
    const optimizedDoc = await io.read(optimized);
    const texture = optimizedDoc.getRoot().listTextures()[0];
    assert(texture?.getMimeType() === 'image/webp', `纹理格式不是 webp：${texture?.getMimeType()}`);
    const extensions = result.extensions ?? [];
    assert(extensions.includes('EXT_meshopt_compression'), `缺少 meshopt：${extensions.join(',')}`);

    const dracoOut = join(directory, 'draco.glb');
    const dracoResult = await optimizeFile({
      input,
      output: dracoOut,
      geometry: 'draco',
      dracoEncodeSpeed: 5,
      dracoPositionBits: 14,
      texture: { format: 'webp', maxSize: 64, quality: 70 },
      simplify: true,
      simplifyRatio: 0.5,
      simplifyError: 0.05,
      simplifyLockBorder: true,
    });
    assert(dracoResult.outputBytes > 0, 'Draco 结果为空');
    const dracoDoc = await io.read(dracoOut);
    assert(dracoDoc.getRoot().listMeshes().length === 1, 'Draco 文件没有网格');

    const stl = join(directory, 'model.stl');
    const stlResult = await convertFile({
      input,
      output: stl,
      target: 'stl',
      unit: 'mm',
      scale: 1,
      center: false,
      weld: true,
    });
    assert(stlResult.triangles > 0, 'STL 没有三角形');
    const stlBytes = await readFile(stl);
    assert(stlBytes.readUInt32LE(80) === stlResult.triangles, 'STL 计数不一致');
    const firstVertexX = stlBytes.readFloatLE(84 + 12);
    assert(firstVertexX > 1000, `节点平移没有烘焙进 STL，x=${firstVertexX}`);

    const centered = join(directory, 'centered.stl');
    await convertFile({
      input,
      output: centered,
      target: 'stl',
      unit: 'm',
      scale: 1,
      center: true,
      weld: true,
    });
    const obj = join(directory, 'model.obj');
    const objResult = await convertFile({
      input,
      output: obj,
      target: 'obj',
      unit: 'm',
      scale: 1,
      center: false,
      weld: true,
    });
    const objText = await readFile(obj, 'utf8');
    assert(objText.includes('\nv '), 'OBJ 没有顶点');
    assert(objResult.triangles > 0, 'OBJ 没有面');

    const gltf = join(directory, 'model.gltf');
    await convertFile({ input, output: gltf, target: 'gltf', scale: 1, center: false, weld: false, unit: 'm' });
    const gltfJSON = JSON.parse(await readFile(gltf, 'utf8'));
    assert(gltfJSON.asset?.version === '2.0', '分离式 glTF 无效');

    const roundTrip = join(directory, 'from-stl.glb');
    const back = await convertFile({
      input: stl,
      output: roundTrip,
      target: 'glb',
      unit: 'mm',
      scale: 1,
      center: false,
      weld: true,
    });
    assert(back.triangles > 0, 'STL → GLB 失败');

    const appleOut = join(directory, 'apple.glb');
    const appleResult = await optimizeFile({
      input,
      output: appleOut,
      compatibility: 'apple',
      texture: { maxSize: 64, quality: 85 },
      simplify: false,
    });
    const appleDoc = await io.read(appleOut);
    const appleExtensions = appleResult.extensions ?? [];
    for (const name of ['EXT_meshopt_compression', 'KHR_draco_mesh_compression', 'KHR_mesh_quantization', 'EXT_texture_webp']) {
      assert(!appleExtensions.includes(name), `macOS 兼容模式仍然使用了 ${name}`);
    }
    assert(appleDoc.getRoot().listTextures()[0]?.getMimeType() === 'image/jpeg', 'macOS 兼容模式纹理不是 JPEG');

    const previewOut = join(directory, 'preview.glb');
    const previewResult = await previewFile({ input: optimized, output: previewOut, maxTriangles: 1 });
    const previewJSON = await readGLBJSON(previewOut);
    for (const name of ['EXT_meshopt_compression', 'KHR_mesh_quantization', 'EXT_texture_webp']) {
      assert(!(previewJSON.extensionsUsed ?? []).includes(name), `预览文件仍然使用了 ${name}`);
    }
    assert(previewJSON.images?.[0]?.mimeType === 'image/png', `预览纹理不是 PNG：${previewJSON.images?.[0]?.mimeType}`);
    assert(previewJSON.accessors.every((accessor) => !accessor.sparse), '预览文件里有 sparse accessor');
    assert(previewResult.simplified && previewResult.sourceTriangles > 0, '预览没有按面数上限简化');

    let rejected = false;
    try {
      await optimizeFile({ input, output: input, texture: { format: 'skip' }, geometry: 'none' });
    } catch (error) {
      rejected = /覆盖/.test(error.message);
    }
    assert(rejected, '没有阻止覆盖源文件');
  } finally {
    await rm(directory, { recursive: true, force: true });
  }

  if (failures.length > 0) {
    process.stderr.write(`${failures.map((item) => `- ${item}`).join('\n')}\n`);
    process.exitCode = 1;
    return;
  }
  process.stdout.write('toolchain selftest passed\n');
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
