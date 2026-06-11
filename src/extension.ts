import * as vscode from 'vscode';
import { exec } from 'child_process';
import { promisify } from 'util';
import * as path from 'path';

const execAsync = promisify(exec);

let decorationType: vscode.TextEditorDecorationType | undefined;
let statusBarItem: vscode.StatusBarItem;

export function activate(context: vscode.ExtensionContext) {
  // 1. Initialize Status Bar Item
  statusBarItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
  statusBarItem.command = 'whereWasI.showMenu';
  statusBarItem.tooltip = 'Where Was I? Settings';
  statusBarItem.show();
  updateStatusBarIcon();
  context.subscriptions.push(statusBarItem);

  // 2. Register Status Bar Menu Command
  const menuCommand = vscode.commands.registerCommand('whereWasI.showMenu', async () => {
    const config = vscode.workspace.getConfiguration('whereWasI');
    const isEnabled = config.get<boolean>('showDiffChanges');

    const items: vscode.QuickPickItem[] = [
      {
        label: `$(eye) ${isEnabled ? 'Disable' : 'Enable'} Highlights`,
        description: 'Toggle showDiffChanges',
      },
      {
        label: '$(symbol-color) Change Highlight Color',
        description: 'Set a new hex color for diffColor',
      },
    ];

    const selection = await vscode.window.showQuickPick(items, { placeHolder: 'Where Was I? Settings' });

    if (selection?.label.includes('Highlights')) {
      await config.update('showDiffChanges', !isEnabled, vscode.ConfigurationTarget.Global);
    } else if (selection?.label.includes('Color')) {
      const currentColor = config.get<string>('diffColor');
      const newColor = await vscode.window.showInputBox({
        prompt: 'Enter a Hex Color (e.g., #3f79c5)',
        value: currentColor,
      });
      if (newColor) {
        await config.update('diffColor', newColor, vscode.ConfigurationTarget.Global);
      }
    }
  });
  context.subscriptions.push(menuCommand);

  // 3. Listeners for Editor and Settings changes
  context.subscriptions.push(
    vscode.window.onDidChangeActiveTextEditor(() => updateDecorations()),
    vscode.workspace.onDidSaveTextDocument(() => updateDecorations()),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration('whereWasI')) {
        updateStatusBarIcon();
        updateDecorationStyle();
        updateDecorations();
      }
    }),
  );

  // Initialize
  updateDecorationStyle();
  updateDecorations();
}

function updateStatusBarIcon() {
  const isEnabled = vscode.workspace.getConfiguration('whereWasI').get<boolean>('showDiffChanges');
  statusBarItem.text = isEnabled ? '$(git-commit) WWI: On' : '$(git-commit) WWI: Off';
}

function updateDecorationStyle() {
  if (decorationType) {
    decorationType.dispose();
  }

  const config = vscode.workspace.getConfiguration('whereWasI');
  const color = config.get<string>('diffColor') || '#3f79c5';

  // Add some transparency (approx 30%) to the hex color so it acts as a soft highlight
  const softColor = color.length === 7 ? color + '4D' : color;

  decorationType = vscode.window.createTextEditorDecorationType({
    backgroundColor: softColor,
    isWholeLine: true,
  });
}

async function updateDecorations() {
  const editor = vscode.window.activeTextEditor;
  if (!editor || !decorationType) {
    return;
  }

  const config = vscode.workspace.getConfiguration('whereWasI');
  if (!config.get<boolean>('showDiffChanges')) {
    editor.setDecorations(decorationType, []);
    return;
  }

  const filePath = editor.document.fileName;
  const cwd = path.dirname(filePath);

  try {
    // Check if it's a git repo
    await execAsync('git rev-parse --is-inside-work-tree', { cwd });

    // Get latest commit hash and author for this specific file
    const { stdout: logOut } = await execAsync(`git log -1 --format="%H|%an" -- "${filePath}"`, { cwd });
    if (!logOut.trim()) {
      editor.setDecorations(decorationType, []);
      return; // No commits for this file yet
    }

    const [hash, commitAuthor] = logOut.trim().split('|');

    // Handle "showYours" logic
    const showYours = config.get<boolean>('showYours');
    if (showYours) {
      const { stdout: configOut } = await execAsync('git config user.name', { cwd });
      const currentAuthor = configOut.trim();
      if (currentAuthor !== commitAuthor) {
        // If authors don't match and showYours is true, do not highlight
        editor.setDecorations(decorationType, []);
        return;
      }
    }

    // Get the diff for this file in its latest commit
    // hash^ means the commit before 'hash'. We compare hash^ to hash
    const { stdout: diffOut } = await execAsync(`git diff ${hash}^ ${hash} -- "${filePath}"`, { cwd });

    const decorations = parseDiffAndGetDecorations(diffOut);
    editor.setDecorations(decorationType, decorations);
  } catch (error) {
    // Fail silently - file might not be tracked by git, git might not be installed, etc.
    editor.setDecorations(decorationType, []);
  }
}

function parseDiffAndGetDecorations(diffText: string): vscode.DecorationOptions[] {
  const lines = diffText.split('\n');
  const decorations: vscode.DecorationOptions[] = [];
  let currentLineNumber = 0; // 0-indexed for VS Code

  for (const line of lines) {
    if (line.startsWith('@@')) {
      // Parse the unified diff chunk header: @@ -start,count +start,count @@
      const match = line.match(/\+([0-9]+)(?:,([0-9]+))?/);
      if (match) {
        currentLineNumber = parseInt(match[1], 10) - 1;
      }
    } else if (line.startsWith('+') && !line.startsWith('+++')) {
      // Added or modified line
      const range = new vscode.Range(currentLineNumber, 0, currentLineNumber, 0);
      decorations.push({ range });
      currentLineNumber++;
    } else if (line.startsWith(' ') || line === '') {
      // Unchanged line
      currentLineNumber++;
    } else if (line.startsWith('-') && !line.startsWith('---')) {
      // Removed line - do not increment the current file's line number
    }
  }

  return decorations;
}

export function deactivate() {
  if (decorationType) {
    decorationType.dispose();
  }
}
