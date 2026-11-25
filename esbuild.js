// Bundles src/extension.ts into dist/extension.js.
//   node esbuild.js               development build (with source maps)
//   node esbuild.js --production  minified build used for the .vsix
//   node esbuild.js --watch       rebuild on change (used by the "watch" task)
const esbuild = require('esbuild');

const production = process.argv.includes('--production');
const watch = process.argv.includes('--watch');

/** Prints build start/end and errors in a format the "watch" task's problem matcher understands. */
/** @type {import('esbuild').Plugin} */
const problemMatcherPlugin = {
	name: 'problem-matcher',
	setup(build) {
		build.onStart(() => {
			console.log('[watch] build started');
		});
		build.onEnd((result) => {
			for (const { text, location } of result.errors) {
				console.error(`✘ [ERROR] ${text}`);
				if (location) {
					console.error(`    ${location.file}:${location.line}:${location.column}:`);
				}
			}
			console.log('[watch] build finished');
		});
	},
};

async function main() {
	const ctx = await esbuild.context({
		entryPoints: ['src/extension.ts'],
		bundle: true,
		format: 'cjs',
		minify: production,
		sourcemap: !production,
		sourcesContent: false,
		platform: 'node',
		target: 'node20',
		outfile: 'dist/extension.js',
		external: ['vscode'],
		logLevel: 'silent',
		plugins: [problemMatcherPlugin],
	});
	if (watch) {
		await ctx.watch();
	} else {
		await ctx.rebuild();
		await ctx.dispose();
	}
}

main().catch((e) => {
	console.error(e);
	process.exit(1);
});
