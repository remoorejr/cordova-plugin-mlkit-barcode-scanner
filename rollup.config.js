import commonjs from '@rollup/plugin-commonjs';
import { nodeResolve } from '@rollup/plugin-node-resolve';
import typescript from '@rollup/plugin-typescript';

/** @type {import('rollup').RollupOptions} */
const options = {
  input: [
    './src-typescript/BarcodeScanner.contract.ts',
    './src-typescript/BarcodeScanner.plugin.ts',
  ],
  output: {
    dir: './www/',
    format: 'cjs',
    sourcemap: 'inline',
  },
  external: ['cordova'],
  plugins: [
    typescript({
      tsconfig: './tsconfig.dist.json',
    }),
    nodeResolve({ browser: true }),
    commonjs(),
  ],
};

export default options;
