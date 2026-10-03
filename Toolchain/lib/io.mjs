import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import draco3d from 'draco3dgltf';
import { MeshoptDecoder, MeshoptEncoder } from 'meshoptimizer';

let ioPromise;

export function createIO() {
  if (!ioPromise) {
    ioPromise = buildIO();
  }
  return ioPromise;
}

async function buildIO() {
  await Promise.all([MeshoptDecoder.ready, MeshoptEncoder.ready]);
  const [decoder, encoder] = await Promise.all([
    draco3d.createDecoderModule(),
    draco3d.createEncoderModule(),
  ]);

  return new NodeIO().registerExtensions(ALL_EXTENSIONS).registerDependencies({
    'draco3d.decoder': decoder,
    'draco3d.encoder': encoder,
    'meshopt.decoder': MeshoptDecoder,
    'meshopt.encoder': MeshoptEncoder,
  });
}

export function extensionNames(document) {
  return document
    .getRoot()
    .listExtensionsUsed()
    .map((extension) => extension.extensionName);
}
