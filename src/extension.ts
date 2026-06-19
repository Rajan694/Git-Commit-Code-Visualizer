import * as vscode from 'vscode';
import { refreshDecorations, updateDecorations, disposeDecorations } from './decorations';
import { initStatusBarItem } from './statusBar';
import { registerCommands } from './commands';

/**
 * Activates the extension.
 * @param context The extension context.
 */
export function activate(context: vscode.ExtensionContext) {
  // 1. Initialize Status Bar Item
  initStatusBarItem(context);

  // 2. Register Commands
  registerCommands(context);

  // 3. Listeners for Editor and Settings changes
  context.subscriptions.push(
    vscode.window.onDidChangeActiveTextEditor(() => void updateDecorations()),
    vscode.workspace.onDidSaveTextDocument(() => void updateDecorations()),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration('whereWasI')) {
        void refreshDecorations();
      }
    }),
  );

  // Initialize
  void refreshDecorations();
}

/**
 * Deactivates the extension, cleaning up any resources.
 */
export function deactivate() {
  disposeDecorations();
}
