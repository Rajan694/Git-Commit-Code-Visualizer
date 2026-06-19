import * as vscode from 'vscode';

let statusBarItem: vscode.StatusBarItem;

/**
 * Initializes the status bar item for the extension.
 * @param context The extension context.
 */
export function initStatusBarItem(context: vscode.ExtensionContext) {
  statusBarItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
  statusBarItem.command = 'whereWasI.showInfoPopup';
  statusBarItem.tooltip = 'Where Was I? Settings';
  statusBarItem.show();
  updateStatusBarIcon();
  context.subscriptions.push(statusBarItem);
}

/**
 * Updates the text and icon of the status bar item based on the extension state.
 */
export function updateStatusBarIcon() {
  if (!statusBarItem) return;
  const isEnabled = vscode.workspace.getConfiguration('whereWasI').get<boolean>('showDiffChanges');
  statusBarItem.text = isEnabled ? '$(git-commit) WWI: On' : '$(git-commit) WWI: Off';
}
