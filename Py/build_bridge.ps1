pyinstaller --onefile `
    --collect-all flask `
    --paths . `
	--hidden-import lingofuse `
    lingofuse\bridge.py
