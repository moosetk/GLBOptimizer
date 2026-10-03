import { convertPrimitiveToTriangles } from '@gltf-transform/functions';

const TRIANGLES = 4;

export function transformPoint(matrix, x, y, z) {
  const x2 = matrix[0] * x + matrix[4] * y + matrix[8] * z + matrix[12];
  const y2 = matrix[1] * x + matrix[5] * y + matrix[9] * z + matrix[13];
  const z2 = matrix[2] * x + matrix[6] * y + matrix[10] * z + matrix[14];
  const w = matrix[3] * x + matrix[7] * y + matrix[11] * z + matrix[15];
  if (!w || Math.abs(w - 1) < 1e-8) {
    return [x2, y2, z2];
  }
  return [x2 / w, y2 / w, z2 / w];
}

export function countTriangles(document) {
  let triangles = 0;
  for (const mesh of document.getRoot().listMeshes()) {
    for (const prim of mesh.listPrimitives()) {
      triangles += primitiveTriangleCount(prim);
    }
  }
  return triangles;
}

function primitiveTriangleCount(prim) {
  const position = prim.getAttribute('POSITION');
  if (!position) return 0;
  const indices = prim.getIndices();
  const count = indices ? indices.getCount() : position.getCount();
  const mode = prim.getMode();
  if (mode === 5 || mode === 6) return Math.max(0, count - 2);
  if (mode === 4 || mode === undefined || mode === null) return Math.floor(count / 3);
  if (mode === 0 || mode === 1 || mode === 2 || mode === 3) return 0;
  return Math.floor(count / 3);
}

/**
 * Walk the default scene and return world-space triangles.
 * Shared meshes are not baked in place; each node contributes its own copy.
 */
export function collectWorldTriangles(document) {
  const warnings = [];
  const root = document.getRoot();
  if (root.listSkins().length > 0) {
    warnings.push('模型包含蒙皮。导出使用绑定姿势，不包含骨骼形变。');
  }

  const scene = root.getDefaultScene() ?? root.listScenes()[0];
  const positions = [];
  const indices = [];
  let vertexBase = 0;

  const consume = (mesh, matrix) => {
    for (const source of mesh.listPrimitives()) {
      let prim = source;
      if (prim.getMode() !== TRIANGLES) {
        try {
          prim = convertPrimitiveToTriangles(prim);
        } catch (error) {
          warnings.push(`跳过非三角形图元${source.getName() ? `（${source.getName()}）` : ''}：${error.message}`);
          continue;
        }
      }
      const position = prim.getAttribute('POSITION');
      if (!position) continue;
      const pointCount = position.getCount();
      const scratch = [0, 0, 0];
      for (let i = 0; i < pointCount; i += 1) {
        const element = position.getElement(i, scratch);
        const world = transformPoint(matrix, element[0], element[1], element[2]);
        positions.push(world[0], world[1], world[2]);
      }
      const indexAccessor = prim.getIndices();
      if (indexAccessor) {
        const raw = indexAccessor.getArray();
        for (let i = 0; i < raw.length; i += 1) {
          indices.push(vertexBase + raw[i]);
        }
      } else {
        for (let i = 0; i < pointCount; i += 1) indices.push(vertexBase + i);
      }
      vertexBase += pointCount;
    }
  };

  const identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
  if (!scene) {
    warnings.push('文件没有场景，已按网格局部坐标导出。');
    for (const mesh of root.listMeshes()) consume(mesh, identity);
  } else {
    if (root.listScenes().length > 1) {
      warnings.push('文件包含多个场景，只导出了默认场景。');
    }
    scene.traverse((node) => {
      const mesh = node.getMesh();
      if (!mesh) return;
      consume(mesh, node.getWorldMatrix());
    });
  }

  return {
    positions: Float32Array.from(positions),
    indices: Uint32Array.from(indices),
    warnings,
  };
}

export function scalePositions(positions, scale) {
  if (scale === 1) return positions;
  const out = new Float32Array(positions.length);
  for (let i = 0; i < positions.length; i += 1) out[i] = positions[i] * scale;
  return out;
}

export function centerPositions(positions) {
  if (positions.length < 3) return { positions, offset: [0, 0, 0] };
  let minX = Infinity;
  let minY = Infinity;
  let minZ = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  let maxZ = -Infinity;
  for (let i = 0; i < positions.length; i += 3) {
    const x = positions[i];
    const y = positions[i + 1];
    const z = positions[i + 2];
    if (x < minX) minX = x;
    if (y < minY) minY = y;
    if (z < minZ) minZ = z;
    if (x > maxX) maxX = x;
    if (y > maxY) maxY = y;
    if (z > maxZ) maxZ = z;
  }
  const cx = (minX + maxX) / 2;
  const cy = (minY + maxY) / 2;
  const cz = (minZ + maxZ) / 2;
  const out = new Float32Array(positions.length);
  for (let i = 0; i < positions.length; i += 3) {
    out[i] = positions[i] - cx;
    out[i + 1] = positions[i + 1] - cy;
    out[i + 2] = positions[i + 2] - cz;
  }
  return { positions: out, offset: [cx, cy, cz] };
}

/**
 * Merge vertices that land on the same quantized cell. This closes tiny
 * cracks that block a watertight STL, without attempting hole filling.
 */
export function weldIndexed(positions, indices) {
  if (positions.length === 0 || indices.length === 0) {
    return { positions, indices, merged: 0 };
  }
  let minX = Infinity;
  let minY = Infinity;
  let minZ = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  let maxZ = -Infinity;
  for (let i = 0; i < positions.length; i += 3) {
    const x = positions[i];
    const y = positions[i + 1];
    const z = positions[i + 2];
    if (x < minX) minX = x;
    if (y < minY) minY = y;
    if (z < minZ) minZ = z;
    if (x > maxX) maxX = x;
    if (y > maxY) maxY = y;
    if (z > maxZ) maxZ = z;
  }
  const extent = Math.max(maxX - minX, maxY - minY, maxZ - minZ, 1e-6);
  const cell = extent * 1e-6;
  const map = new Map();
  const remap = new Uint32Array(positions.length / 3);
  const welded = [];
  let merged = 0;

  for (let vertex = 0; vertex < remap.length; vertex += 1) {
    const x = positions[vertex * 3];
    const y = positions[vertex * 3 + 1];
    const z = positions[vertex * 3 + 2];
    const key = `${Math.round(x / cell)}:${Math.round(y / cell)}:${Math.round(z / cell)}`;
    const existing = map.get(key);
    if (existing === undefined) {
      const next = welded.length / 3;
      map.set(key, next);
      remap[vertex] = next;
      welded.push(x, y, z);
    } else {
      remap[vertex] = existing;
      merged += 1;
    }
  }

  const nextIndices = new Uint32Array(indices.length);
  for (let i = 0; i < indices.length; i += 1) nextIndices[i] = remap[indices[i]];
  return { positions: Float32Array.from(welded), indices: nextIndices, merged };
}

export function buildBinarySTL(positions, indices) {
  const triangleCount = Math.floor(indices.length / 3);
  const body = Buffer.alloc(triangleCount * 50);
  let written = 0;
  for (let i = 0; i + 2 < indices.length; i += 3) {
    const a = indices[i] * 3;
    const b = indices[i + 1] * 3;
    const c = indices[i + 2] * 3;
    const ax = positions[a];
    const ay = positions[a + 1];
    const az = positions[a + 2];
    const bx = positions[b];
    const by = positions[b + 1];
    const bz = positions[b + 2];
    const cx = positions[c];
    const cy = positions[c + 1];
    const cz = positions[c + 2];
    const abx = bx - ax;
    const aby = by - ay;
    const abz = bz - az;
    const acx = cx - ax;
    const acy = cy - ay;
    const acz = cz - az;
    let nx = aby * acz - abz * acy;
    let ny = abz * acx - abx * acz;
    let nz = abx * acy - aby * acx;
    const length = Math.hypot(nx, ny, nz);
    if (length < 1e-12) continue;
    nx /= length;
    ny /= length;
    nz /= length;
    const offset = written * 50;
    body.writeFloatLE(nx, offset);
    body.writeFloatLE(ny, offset + 4);
    body.writeFloatLE(nz, offset + 8);
    body.writeFloatLE(ax, offset + 12);
    body.writeFloatLE(ay, offset + 16);
    body.writeFloatLE(az, offset + 20);
    body.writeFloatLE(bx, offset + 24);
    body.writeFloatLE(by, offset + 28);
    body.writeFloatLE(bz, offset + 32);
    body.writeFloatLE(cx, offset + 36);
    body.writeFloatLE(cy, offset + 40);
    body.writeFloatLE(cz, offset + 44);
    body.writeUInt16LE(0, offset + 48);
    written += 1;
  }

  const header = Buffer.alloc(84);
  header.write('GLB Optimizer binary STL', 0, 'ascii');
  header.writeUInt32LE(written, 80);
  return { bytes: Buffer.concat([header, body.subarray(0, written * 50)]), triangles: written };
}

export function objText(positions, indices) {
  const lines = ['# Generated by GLB Optimizer'];
  for (let i = 0; i < positions.length; i += 3) {
    lines.push(`v ${positions[i]} ${positions[i + 1]} ${positions[i + 2]}`);
  }
  let faces = 0;
  for (let i = 0; i + 2 < indices.length; i += 3) {
    const a = indices[i];
    const b = indices[i + 1];
    const c = indices[i + 2];
    if (a === b || b === c || a === c) continue;
    lines.push(`f ${a + 1} ${b + 1} ${c + 1}`);
    faces += 1;
  }
  return { text: `${lines.join('\n')}\n`, triangles: faces };
}

export function prepareMesh(document, { weld }) {
  const gathered = collectWorldTriangles(document);
  let { positions, indices } = gathered;
  const warnings = gathered.warnings.slice();
  if (weld) {
    const welded = weldIndexed(positions, indices);
    positions = welded.positions;
    indices = welded.indices;
    if (welded.merged > 0) {
      warnings.push(`已焊接 ${welded.merged} 个重合顶点。缝隙过大时仍可能不是完全水密网格。`);
    }
  }
  return { positions, indices, warnings };
}
