# 需要安装py installer

pyinstaller --onefile `
    --paths . `
    --collect-all llama_cpp `
    --collect-all lingofuse `
    --hidden-import llama_cpp `
    --hidden-import lingofuse `
    llm-service\llm_service.py
	