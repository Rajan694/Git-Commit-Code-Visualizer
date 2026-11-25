import * as assert from 'assert';
import * as vscode from 'vscode';

const EXTENSION_ID = 'rajan694.where-was-i';

suite('Where Was I?', () => {
	test('is installed', () => {
		assert.ok(vscode.extensions.getExtension(EXTENSION_ID));
	});

	test('activates and registers every contributed command', async () => {
		const extension = vscode.extensions.getExtension(EXTENSION_ID)!;
		await extension.activate();
		assert.strictEqual(extension.isActive, true);

		const registered = await vscode.commands.getCommands(true);
		const contributed: { command: string }[] = extension.packageJSON.contributes.commands;
		for (const { command } of contributed) {
			assert.ok(registered.includes(command), `${command} is contributed in package.json but not registered`);
		}
	});
});
