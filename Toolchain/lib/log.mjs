import { writeSync } from 'node:fs';

export function emit(event) {
  writeSync(1, `${JSON.stringify(event)}\n`);
}

export function progress(message, fraction) {
  const event = { type: 'progress', message };
  if (typeof fraction === 'number' && Number.isFinite(fraction)) {
    event.fraction = Math.max(0, Math.min(1, fraction));
  }
  emit(event);
}

export function captureConsole() {
  if (captureConsole.installed) return;
  captureConsole.installed = true;
  for (const level of ['log', 'info', 'warn']) {
    console[level] = (...args) => {
      const text = args
        .map((item) => (typeof item === 'string' ? item : item?.message || String(item)))
        .join(' ')
        .trim();
      if (text) progress(text);
    };
  }
}

export function fail(error) {
  const message = error instanceof Error ? error.message : String(error);
  emit({ type: 'error', message });
  if (error instanceof Error && error.stack) {
    writeSync(2, `${error.stack}\n`);
  }
}
