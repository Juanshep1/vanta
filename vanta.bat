@echo off
REM Vanta launcher (Windows). Put this directory on your PATH to use `vanta`.
REM Uses python3 if it really runs (not the Microsoft Store stub), else the py launcher (py -3), else python.
python3 --version >nul 2>nul
if %ERRORLEVEL%==0 (
    python3 "%~dp0vanta.py" %*
    exit /b %ERRORLEVEL%
)
py -3 --version >nul 2>nul
if %ERRORLEVEL%==0 (
    py -3 "%~dp0vanta.py" %*
    exit /b %ERRORLEVEL%
)
python "%~dp0vanta.py" %*
exit /b %ERRORLEVEL%
