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

    const choice = await vscode.window.showInformationMessage(
      'Where Was I Settings',
      'Toggle Highlights',
      'Toggle My Commits',
      'Change Highlight Color',
    );
    switch (choice) {
      case 'Toggle Highlights':
        await config.update('showDiffChanges', !isEnabled, vscode.ConfigurationTarget.Global);
        break;
      case 'Toggle My Commits':
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
}
