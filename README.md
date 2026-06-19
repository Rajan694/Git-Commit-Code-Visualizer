# Where Was I?

"Where Was I?" is a Visual Studio Code extension that helps you quickly identify recent code changes by visualizing the latest git commit differences using soft background gradients directly in your editor. 

It's perfect for jumping back into a project and instantly seeing what you (or others) were last working on.

## Features

- **Inline Git Highlights**: Visually highlights lines modified in the most recent commit for the currently open file.
- **Customizable Colors**: Choose from multiple preset highlight colors (Ocean Blue, Mint Green, Amber, Rose, Violet) to suit your theme.
- **Filter by Author**: An optional "Show Yours" setting restricts highlights to only show up if *you* were the author of the latest commit, helping you focus strictly on your own recent work.
- **Status Bar Integration**: Provides a convenient status bar item indicating whether highlights are currently enabled or disabled.
- **Quick Settings Menu**: Click the status bar item to open a quick-access popup menu where you can toggle highlights, toggle the author filter, or change the highlight color on the fly.

## Extension Settings

This extension contributes the following configurable settings:

- `whereWasI.showDiffChanges`: Enable or disable the highlighting of recent git changes globally. (Default: `true`)
- `whereWasI.diffColor`: Select the soft background color used for highlighting changed lines. (Default: `#3f79c5` - Ocean Blue)
- `whereWasI.showYours`: When enabled, only highlights changes if your configured git username matches the author of the file's latest commit. (Default: `false`)

## Commands

- `Where Was I: Settings Menu` (`whereWasI.showMenu`): Opens the interactive quick-pick menu to adjust your highlight preferences without needing to open the VS Code settings UI.

## Requirements

- **Git**: The extension relies on the `git` command-line tool being installed and accessible in your system's PATH. It functions by analyzing the local git history of your repository workspace.

## Release Notes

### 0.0.1
- Initial release! Core highlighting features, customizable colors, and status bar integration.
