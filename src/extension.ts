import * as vscode from 'vscode';
import { exec } from 'child_process';
import { promisify } from 'util';
import * as path from 'path';

const execAsync = promisify(exec);
const PRESET_COLORS = [
  { label: 'Ocean Blue', value: '#3f79c5' },
  { label: 'Mint Green', value: '#4caf50' },
  { label: 'Amber', value: '#ff9800' },
  { label: 'Rose', value: '#e91e63' },
  { label: 'Violet', value: '#9c27b0' },
] as const;

let decorationType: vscode.TextEditorDecorationType | undefined;
let statusBarItem: vscode.StatusBarItem;

export function activate(context: vscode.ExtensionContext) {
  // 1. Initialize Status Bar Item
  statusBarItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
  statusBarItem.command = 'whereWasI.showInfoPopup';
  statusBarItem.tooltip = 'Where Was I? Settings';
  statusBarItem.show();
  updateStatusBarIcon();
  context.subscriptions.push(statusBarItem);

  // 2. Register Status Bar Info Popup Command
  const infoCommand = vscode.commands.registerCommand('whereWasI.showInfoPopup', async () => {
    const config = vscode.workspace.getConfiguration('whereWasI');
    const isEnabled = config.get<boolean>('showDiffChanges');
    const showYours = config.get<boolean>('showYours');
    const currentColor = config.get<string>('diffColor') || PRESET_COLORS[0].value;

    const choice = await vscode.window.showInformationMessage(
      'Where Was I Settings',
      'Toggle Highlights',
      'Toggle My Commits',
      'Change Highlight Color',
    );
    switch (choice) {
      case 'Toggle Highlights':
        await config.update('showDiffChanges', !isEnabled, vscode.ConfigurationTarget.Global);
        await refreshDecorations();
        break;
      case 'Toggle My Commits':
        await config.update('showYours', !showYours, vscode.ConfigurationTarget.Global);
        await refreshDecorations();
        break;
      case 'Change Highlight Color': {
        const colorPick = await vscode.window.showQuickPick(
          PRESET_COLORS.map((color) => ({
            label: color.label,
            description: color.value,
            value: color.value,
          })),
          { placeHolder: 'Choose a highlight color' },
        );
        if (colorPick) {
          await config.update('diffColor', colorPick.value, vscode.ConfigurationTarget.Global);
          await refreshDecorations();
        }
        break;
      }
    }
  });
  context.subscriptions.push(infoCommand);

  // Helper to generate the HTML content for the popover
  function getWebviewContent(): string {
    const config = vscode.workspace.getConfiguration('whereWasI');
    const isEnabled = config.get<boolean>('showDiffChanges');
    const showYours = config.get<boolean>('showYours');
    const currentColor = config.get<string>('diffColor') || PRESET_COLORS[0].value;
    return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <style>
    body { font-family: var(--vscode-editor-font-family, sans-serif); padding: 10px; }
    button { margin: 5px 0; width: 100%; padding: 5px; }
  </style>
</head>
<body>
  <button id="highlights">${isEnabled ? 'Disable' : 'Enable'} Highlights</button>
  <button id="yours">Show My Commits: ${showYours ? 'On' : 'Off'}</button>
  <button id="color">Change Highlight Color (Current: ${currentColor})</button>
  <script>
    const vscode = acquireVsCodeApi();
    document.getElementById('highlights').addEventListener('click', () => {
      vscode.postMessage({ command: 'toggleHighlights' });
    });
    document.getElementById('yours').addEventListener('click', () => {
      vscode.postMessage({ command: 'toggleYours' });
    });
    document.getElementById('color').addEventListener('click', () => {
      vscode.postMessage({ command: 'changeColor' });
    });
    // Close the panel when it loses focus
    window.addEventListener('blur', () => {
      vscode.postMessage({ command: 'dispose' });
    });
  </script>
</body>
</html>`;
  }

  // Keep a reference to the panel so we can reuse or dispose it
  let popoverPanel: vscode.WebviewPanel | undefined;

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

function updateStatusBarIcon() {
  const isEnabled = vscode.workspace.getConfiguration('whereWasI').get<boolean>('showDiffChanges');
  statusBarItem.text = isEnabled ? '$(git-commit) WWI: On' : '$(git-commit) WWI: Off';
}

function updateDecorationStyle() {
  if (decorationType) {
    for (const editor of vscode.window.visibleTextEditors) {
      editor.setDecorations(decorationType, []);
    }
    decorationType.dispose();
  }

  const config = vscode.workspace.getConfiguration('whereWasI');
  const color = config.get<string>('diffColor') || PRESET_COLORS[0].value;

  // Add some transparency (approx 30%) to the hex color so it acts as a soft highlight
  const softColor = color.length === 7 ? `${color}4D` : color;

  decorationType = vscode.window.createTextEditorDecorationType({
    backgroundColor: softColor,
    isWholeLine: true,
  });
}

async function refreshDecorations() {
  updateStatusBarIcon();
  updateDecorationStyle();
  await updateDecorations();
}

async function updateDecorations() {
  if (!decorationType) {
    return;
  }

  const editors = vscode.window.visibleTextEditors;
  await Promise.all(editors.map((editor) => updateDecorationsForEditor(editor)));
}

async function updateDecorationsForEditor(editor: vscode.TextEditor) {
  if (!decorationType) {
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
    if (!showYours) {
      const { stdout: configOut } = await execAsync('git config user.name', { cwd });
      const currentAuthor = configOut.trim();
      if (currentAuthor === commitAuthor) {
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
