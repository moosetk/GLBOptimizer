import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

export async function readJob(jobPath) {
  let parsed;
  try {
    parsed = JSON.parse(await readFile(jobPath, 'utf8'));
  } catch (error) {
    throw new Error(`无法读取任务文件：${error.message}`);
  }
  if (!parsed.input || !parsed.output) {
    throw new Error('任务缺少 input 或 output 路径。');
  }
  parsed.input = resolve(parsed.input);
  parsed.output = resolve(parsed.output);
  return parsed;
}

export function samePath(a, b) {
  return resolve(a) === resolve(b);
}
