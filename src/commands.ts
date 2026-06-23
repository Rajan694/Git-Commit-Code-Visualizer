import * as vscode from 'vscode';
import { PRESET_COLORS } from './constants';

/**
 * Registers commands for the extension.
 * @param context The extension context.
 */
export function registerCommands(context: vscode.ExtensionContext) {
  const infoCommand = vscode.commands.registerCommand('whereWasI.showInfoPopup', async () => {
    const config = vscode.workspace.getConfiguration('whereWasI');
    const isEnabled = config.get<boolean>('showDiffChanges');
    const showYours = config.get<boolean>('showYours');

    const highlightLabel = isEnabled ? 'Hide Highlights' : 'Show Highlights';
    const mineLabel = showYours ? 'Hide Mine' : 'Show Mine';

    const choice = await vscode.window.showInformationMessage(
      'Where Was I (Ctrl + Alt + W)',
      highlightLabel,
      mineLabel,
      'Change Highlight Color',
    );
    switch (choice) {
      case 'Show Highlights':
      case 'Hide Highlights':
        await config.update('showDiffChanges', !isEnabled, vscode.ConfigurationTarget.Global);
        break;
      case 'Show Mine':
      case 'Hide Mine':
        await config.update('showYours', !showYours, vscode.ConfigurationTarget.Global);
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
        }
        break;
      }
    }
  });
  context.subscriptions.push(infoCommand);

  /**
   * Toggles the `showDiffChanges` setting on/off.
   * Bound to Ctrl+Alt+W via the keybindings contribution in package.json.
   */
  const toggleHighlightsCommand = vscode.commands.registerCommand('whereWasI.toggleHighlights', async () => {
    const config = vscode.workspace.getConfiguration('whereWasI');
    const current = config.get<boolean>('showDiffChanges') ?? true;
    await config.update('showDiffChanges', !current, vscode.ConfigurationTarget.Global);
    void vscode.window.setStatusBarMessage(`Where Was I: Highlights ${!current ? 'enabled' : 'disabled'}`, 3000);
  });
  context.subscriptions.push(toggleHighlightsCommand);
}
