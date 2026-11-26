import { defineConfig } from '@vscode/test-cli';
import * as os from 'os';
import * as path from 'path';

export default defineConfig({
	files: 'out/test/**/*.test.js',
	// The default, .vscode-test/user-data in this repository, makes VS Code's IPC socket path
	// longer than macOS allows (103 characters) on CI, where the long repository name appears twice.
	launchArgs: [`--user-data-dir=${path.join(os.tmpdir(), 'gccv-vscode-test')}`],
});
