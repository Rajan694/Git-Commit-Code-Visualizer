# Install from the `.vsix` file

Use this file if you want to install the extension directly in VS Code without using the marketplace.

## Download the release asset

1. Open the GitHub release for this extension.
2. Download the `.vsix` file from the release assets.
3. Save the file somewhere easy to find, such as your `Downloads` folder.

## Install in VS Code

### Option 1: From the Extensions view

1. Open VS Code.
2. Open the Extensions view with `Ctrl+Shift+X` on Windows/Linux or `Cmd+Shift+X` on macOS.
3. Click the `...` menu in the top-right of the Extensions panel.
4. Select `Install from VSIX...`
5. Choose the downloaded `.vsix` file.
6. Reload VS Code when prompted.

### Option 2: From the command line

If you prefer the terminal, run:

```bash
code --install-extension /path/to/your-extension.vsix
```

Replace `/path/to/your-extension.vsix` with the actual file path.

## Verify the installation

1. Open the Extensions view again.
2. Search for the extension name.
3. Confirm it shows as installed and enabled.

## Updating later

When a new release is published, download the new `.vsix` file and repeat the same steps to upgrade.

## Troubleshooting

- If VS Code says the file is invalid, make sure you downloaded the `.vsix` from the release assets and not the source code archive.
- If the install button does nothing, restart VS Code and try again.
- On Linux, you may need to use the full path to the `code` command if it is not on your `PATH`.
