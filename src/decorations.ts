import * as vscode from 'vscode';
import { exec } from 'child_process';
import { promisify } from 'util';
import * as path from 'path';
import { PRESET_COLORS } from './constants';
import { updateStatusBarIcon } from './statusBar';

const execAsync = promisify(exec);
let decorationType: vscode.TextEditorDecorationType | undefined;

/**
 * Updates the decoration style based on the current configuration.
 */
export function updateDecorationStyle() {
  const config = vscode.workspace.getConfiguration('whereWasI');
  const color = config.get<string>('diffColor') || PRESET_COLORS[0].value;

  // Add some transparency (approx 30%) to the hex color so it acts as a soft highlight
  const softColor = color.length === 7 ? `${color}4D` : color;

  decorationType = vscode.window.createTextEditorDecorationType({
    backgroundColor: softColor,
    isWholeLine: true,
  });
}

/**
 * Refreshes all decorations across all visible editors.
 */
export async function refreshDecorations() {
  updateStatusBarIcon();
  // Always clear existing decorations first
  clearAllDecorations();

  const config = vscode.workspace.getConfiguration('whereWasI');
  const isEnabled = config.get<boolean>('showDiffChanges');
  if (!isEnabled) {
    return;
  }

  updateDecorationStyle();
  await updateDecorations();
}

/**
 * Clears all decorations from all visible text editors.
 */
export function clearAllDecorations() {
  if (!decorationType) {
    return;
  }
  for (const editor of vscode.window.visibleTextEditors) {
    editor.setDecorations(decorationType, []);
  }
  decorationType.dispose();
  decorationType = undefined;
}

/**
 * Updates decorations for all visible text editors.
 */
export async function updateDecorations() {
  if (!decorationType) {
    return;
  }
  const editors = vscode.window.visibleTextEditors;
  await Promise.all(editors.map((editor) => updateDecorationsForEditor(editor)));
}

/**
 * Updates decorations for a specific text editor based on git commit history.
 * @param editor The text editor to update decorations for.
 */
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
    console.error(error);
    editor.setDecorations(decorationType, []);
  }
}

/**
 * Parses a git diff output and generates vscode decoration options.
 * @param diffText The unified diff text to parse.
 * @returns An array of decoration options representing the changed lines.
 */
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

/**
 * Disposes of the current decoration type to clean up resources.
 */
export function disposeDecorations() {
  if (decorationType) {
    decorationType.dispose();
  }
}
