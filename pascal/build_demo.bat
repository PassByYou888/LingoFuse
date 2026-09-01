@echo off

:: 检查 PATH 中是否存在 lazbuild.exe
where lazbuild.exe >nul 2>&1
if errorlevel 1 (
    echo 在系统环境参数里面,设置一个Lazarus的路径就可以编译了
    echo 错误：未找到 lazbuild.exe，请确保 Lazarus 已安装，并将 lazbuild.exe 所在目录添加到 PATH 环境变量中。
    pause
    exit /b
)

:: 找到 lazbuild.exe，执行编译
lazbuild.exe -B fpc_tester_for_LingoFuse.lpi
lazbuild.exe -B LingoFuseBenchClient.lpi
lazbuild.exe -B LingoFuseBenchServer.lpi
lazbuild.exe -B LingoFuseBench_API_Check.lpi

:: 子目录编译，使用 pushd/popd
for %%d in (bridge cross_demo SequenceData Compute_Grid_Demo) do (
    pushd "%%d"
    echo 进入 %%d 编译...
    call build.bat
    if errorlevel 1 (
        echo %%d 编译失败！
        popd
        exit /b
    )
    popd
)

echo 所有项目编译完成。
pause