const esbuild = require('esbuild');
const fs = require('fs');
const path = require('path');

// Ensure dist directory exists
const distDir = path.join(__dirname, 'dist');
if (!fs.existsSync(distDir)) {
  fs.mkdirSync(distDir, { recursive: true });
}

// Build configurations
const builds = [
  // ESM
  {
    entryPoints: ['hornbeam.js'],
    outfile: 'dist/hornbeam.esm.js',
    format: 'esm',
    bundle: true,
    minify: false,
    sourcemap: true,
  },
  // ESM minified
  {
    entryPoints: ['hornbeam.js'],
    outfile: 'dist/hornbeam.esm.min.js',
    format: 'esm',
    bundle: true,
    minify: true,
    sourcemap: true,
  },
  // CommonJS
  {
    entryPoints: ['hornbeam.js'],
    outfile: 'dist/hornbeam.cjs.js',
    format: 'cjs',
    bundle: true,
    minify: false,
    sourcemap: true,
  },
  // UMD (for browsers)
  {
    entryPoints: ['hornbeam.js'],
    outfile: 'dist/hornbeam.umd.js',
    format: 'iife',
    globalName: 'Hornbeam',
    bundle: true,
    minify: false,
    sourcemap: true,
  },
  // UMD minified
  {
    entryPoints: ['hornbeam.js'],
    outfile: 'dist/hornbeam.umd.min.js',
    format: 'iife',
    globalName: 'Hornbeam',
    bundle: true,
    minify: true,
    sourcemap: true,
  },
];

async function build() {
  console.log('Building hornbeam-js...');

  for (const config of builds) {
    try {
      await esbuild.build(config);
      console.log(`  Built ${config.outfile}`);
    } catch (error) {
      console.error(`  Failed to build ${config.outfile}:`, error);
      process.exit(1);
    }
  }

  // Copy TypeScript definitions
  const typesContent = fs.readFileSync(
    path.join(__dirname, 'hornbeam.d.ts'),
    'utf-8'
  );
  fs.writeFileSync(
    path.join(distDir, 'hornbeam.d.ts'),
    typesContent
  );
  console.log('  Copied hornbeam.d.ts');

  console.log('Build complete!');
}

build();
