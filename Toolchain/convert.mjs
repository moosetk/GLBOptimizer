import { readFile, stat, writeFile } from 'node:fs/promises';
import { extname } from 'node:path';
import { Document } from '@gltf-transform/core';
import { center, dequantize, weld } from '@gltf-transform/functions';
import { createIO } from './lib/io.mjs';
import {
  buildBinarySTL,
  centerPositions,
  objText,
  prepareMesh,
  scalePositions,
} from './lib/geometry.mjs';
import { fail, progress, captureConsole } from './lib/log.mjs';
import { readJob, samePath } from './lib/job.mjs';
import { pathToFileURL } from 'node:url';

const TO_UNIT = {
  m: 1,
  mm: 1000,
  cm: 100,
  inch: 39.37007874015748,
};

const TO_METERS = {
  m: 1,
  mm: 0.001,
  cm: 0.01,
  inch: 0.0254,
};

export async function convertFile(job) {
  captureConsole();
  const started = Date.now();
  if (samePath(job.input, job.output)) {
    throw new Error('输出路径与源文件相同，已取消以免覆盖原文件。');
  }
  const inputExt = extname(job.input).toLowerCase();
  const target = job.target;
  progress('正在读取模型', 0.08);

  if (inputExt === '.stl') {
    if (target !== 'glb') {
      throw new Error('STL 目前只能转换成 GLB。材质在 STL 里本来就不存在。');
    }
    return stlToGlb(job, started);
  }
  if (inputExt === '.obj') {
    if (target !== 'glb') {
      throw new Error('OBJ 目前只能转换成 GLB。会读取顶点与面，不读取材质库。');
    }
    return objToGlb(job, started);
  }
  if (inputExt !== '.glb' && inputExt !== '.gltf') {
    throw new Error(`不支持的输入格式 ${inputExt || '(无扩展名)'}。`);
  }
  if (!['stl', 'obj', 'gltf', 'glb'].includes(target)) {
    throw new Error(`不支持的目标格式 ${target}。`);
  }

  const io = await createIO();
  const document = await io.read(job.input);
  progress('正在整理网格', 0.35);
  await document.transform(dequantize());
  if (job.weld !== false && (target === 'stl' || target === 'obj')) {
    await document.transform(weld());
  }

  const crossing = target === 'stl' || target === 'obj';
  const warnings = [];
  if (crossing) {
    warnings.push('STL/OBJ 只保留几何。材质、纹理、动画不会被保留。');
    const scale = crossingScale(job, 'from-gltf');
    const prepared = prepareMesh(document, { weld: job.weld !== false });
    warnings.push(...prepared.warnings.filter((item) => !warnings.includes(item)));
    let positions = scalePositions(prepared.positions, scale);
    if (job.center) {
      positions = centerPositions(positions).positions;
    }
    progress('正在写出文件', 0.8);
    if (positions.length === 0) {
      throw new Error('没有可导出的三角形。模型可能只有点或线，或者几何被 Draco/Meshopt 以外的扩展包住了。');
    }
    if (target === 'stl') {
      const stl = buildBinarySTL(positions, prepared.indices);
      if (stl.triangles === 0) {
        throw new Error('所有三角形都退化了，没有写出 STL。');
      }
      await writeFile(job.output, stl.bytes);
      return finish(job, started, { triangles: stl.triangles, warnings });
    }
    const obj = objText(positions, prepared.indices);
    await writeFile(job.output, obj.text);
    return finish(job, started, { triangles: obj.triangles, warnings });
  }

  const scale = Number(job.scale ?? 1);
  if (scale !== 1) {
    const matrix = [scale, 0, 0, 0, 0, scale, 0, 0, 0, 0, scale, 0, 0, 0, 0, 1];
    const { transformMesh } = await import('@gltf-transform/functions');
    for (const mesh of document.getRoot().listMeshes()) {
      transformMesh(mesh, matrix);
    }
  }
  if (job.center) {
    await document.transform(center({ pivot: 'center' }));
  }
  progress('正在写出文件', 0.8);
  await io.write(job.output, document);
  const triangles = countFallback(document);
  return finish(job, started, { triangles, warnings });
}

async function stlToGlb(job, started) {
  const bytes = await readFile(job.input);
  const parsed = parseSTL(bytes);
  return meshExchangeToGlb(job, started, parsed.positions, parsed.indices, [
    `STL 已按「${unitLabel(job.unit)}」换算成 glTF 的米。`,
  ]);
}

async function objToGlb(job, started) {
  const text = await readFile(job.input, 'utf8');
  const parsed = parseOBJ(text);
  return meshExchangeToGlb(job, started, parsed.positions, parsed.indices, [
    'OBJ 转换只读取顶点和面，mtllib / 贴图会被忽略。',
  ]);
}

async function meshExchangeToGlb(job, started, positions, indices, warnings) {
  let nextPositions = scalePositions(positions, crossingScale(job, 'to-gltf'));
  if (job.center) nextPositions = centerPositions(nextPositions).positions;
  if (job.weld !== false) {
    const { weldIndexed } = await import('./lib/geometry.mjs');
    const welded = weldIndexed(nextPositions, indices);
    nextPositions = welded.positions;
    indices = welded.indices;
  }
  const io = await createIO();
  const document = new Document();
  const buffer = document.createBuffer();
  const position = document
    .createAccessor()
    .setType('VEC3')
    .setArray(nextPositions)
    .setBuffer(buffer);
  const index = document
    .createAccessor()
    .setType('SCALAR')
    .setArray(indices)
    .setBuffer(buffer);
  const primitive = document.createPrimitive().setAttribute('POSITION', position).setIndices(index);
  const mesh = document.createMesh('converted').addPrimitive(primitive);
  const node = document.createNode('converted').setMesh(mesh);
  document.createScene('converted').addChild(node);
  if (job.weld !== false) await document.transform(weld());
  progress('正在写出 GLB', 0.8);
  await io.write(job.output, document);
  return finish(job, started, { triangles: Math.floor(indices.length / 3), warnings });
}

function crossingScale(job, direction) {
  const userScale = Number(job.scale ?? 1);
  if (!Number.isFinite(userScale) || userScale <= 0) {
    throw new Error('缩放倍率必须是大于 0 的数字。');
  }
  const unit = job.unit ?? 'm';
  const table = direction === 'from-gltf' ? TO_UNIT : TO_METERS;
  const factor = table[unit];
  if (!factor) throw new Error(`不支持的单位 ${unit}。可用 m、mm、cm、inch。`);
  return factor * userScale;
}

function parseSTL(bytes) {
  if (bytes.length < 84) throw new Error('STL 文件太小，无法解析。');
  const head = bytes.subarray(0, 80).toString('utf8').trim().toLowerCase();
  if (head.startsWith('solid') && !looksLikeBinarySTL(bytes)) {
    return parseASCIISTL(bytes.toString('utf8'));
  }
  const count = bytes.readUInt32LE(80);
  const expected = 84 + count * 50;
  if (count > 0 && expected <= bytes.length + 50) {
    const positions = new Float32Array(count * 9);
    const indices = new Uint32Array(count * 3);
    for (let i = 0; i < count; i += 1) {
      const offset = 84 + i * 50;
      if (offset + 48 > bytes.length) break;
      for (let v = 0; v < 9; v += 1) {
        positions[i * 9 + v] = bytes.readFloatLE(offset + 12 + v * 4);
        indices[i * 3 + Math.floor(v / 3)] = i * 3 + Math.floor(v / 3);
      }
    }
    return { positions, indices };
  }
  if (head.startsWith('solid')) return parseASCIISTL(bytes.toString('utf8'));
  throw new Error('无法识别这个 STL。请使用二进制 STL，或标准的 ASCII STL。');
}

function looksLikeBinarySTL(bytes) {
  if (bytes.length < 84) return false;
  const count = bytes.readUInt32LE(80);
  const expected = 84 + count * 50;
  return count > 0 && Math.abs(bytes.length - expected) < 100;
}

function parseASCIISTL(text) {
  const positions = [];
  const indices = [];
  const pattern = /vertex\s+([+-eE0-9.]+)\s+([+-eE0-9.]+)\s+([+-eE0-9.]+)/g;
  let match = pattern.exec(text);
  let vertex = 0;
  while (match) {
    positions.push(Number(match[1]), Number(match[2]), Number(match[3]));
    indices.push(vertex);
    vertex += 1;
    match = pattern.exec(text);
  }
  if (positions.length < 9) throw new Error('ASCII STL 里没有找到三角形。');
  return { positions: Float32Array.from(positions), indices: Uint32Array.from(indices) };
}

function parseOBJ(text) {
  const positions = [];
  const indices = [];
  const vertices = [];
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line.startsWith('v ')) {
      const parts = line.split(/\s+/);
      vertices.push(Number(parts[1]), Number(parts[2]), Number(parts[3]));
      continue;
    }
    if (!line.startsWith('f ')) continue;
    const corners = line.split(/\s+/).slice(1).map(faceIndex);
    if (corners.length < 3 || corners.some((index) => !Number.isInteger(index))) {
      throw new Error(`无法解析 OBJ 面：${line}`);
    }
    const base = positions.length / 3;
    for (const index of corners) {
      const resolved = index > 0 ? index - 1 : vertices.length / 3 + index;
      positions.push(vertices[resolved * 3], vertices[resolved * 3 + 1], vertices[resolved * 3 + 2]);
    }
    for (let i = 1; i < corners.length - 1; i += 1) {
      indices.push(base, base + i, base + i + 1);
    }
  }
  if (indices.length < 3) throw new Error('OBJ 里没有找到面。');
  return { positions: Float32Array.from(positions), indices: Uint32Array.from(indices) };
}

function faceIndex(token) {
  const index = Number(token.split('/')[0]);
  return index;
}

async function finish(job, started, extra) {
  const [inputStat, outputStat] = await Promise.all([stat(job.input), stat(job.output)]);
  progress('转换完成', 1);
  return {
    type: 'result',
    output: job.output,
    inputBytes: inputStat.size,
    outputBytes: outputStat.size,
    elapsedMs: Date.now() - started,
    triangles: extra.triangles ?? 0,
    warnings: extra.warnings ?? [],
  };
}

function countFallback(document) {
  let triangles = 0;
  for (const mesh of document.getRoot().listMeshes()) {
    for (const prim of mesh.listPrimitives()) {
      const indices = prim.getIndices();
      const position = prim.getAttribute('POSITION');
      const count = indices ? indices.getCount() : position?.getCount() ?? 0;
      triangles += Math.floor(count / 3);
    }
  }
  return triangles;
}

function unitLabel(unit) {
  return { m: '米', mm: '毫米', cm: '厘米', inch: '英寸' }[unit] ?? unit ?? '米';
}

async function main() {
  const jobPath = process.argv[2];
  if (!jobPath) throw new Error('用法：node convert.mjs <job.json>');
  const job = await readJob(jobPath);
  const result = await convertFile(job);
  const { emit } = await import('./lib/log.mjs');
  emit(result);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    fail(error);
    process.exitCode = 1;
  });
}
