; 文件互传助手 (Windows) NSIS 安装包脚本
;
; 构建方式（脚本用 __FILEDIR__ 定位仓库根目录，必须传本文件的绝对路径）：
;   makensis /INPUTCHARSET UTF8 <本文件的绝对路径>
; 依赖：
;   1) 已发布的 windows\publish\release-build\ADBTypeLink.App.exe（自包含单文件）
;   2) NSIS 3.x（Unicode 版，含 Modern UI 2 与 nsDialogs）
; 产物：
;   release\文件互传助手-<版本>-安装包.exe

Unicode true
SetCompressor /SOLID lzma
SetCompressorDictSize 64
RequestExecutionLevel user
ManifestDPIAware true

!include "MUI2.nsh"
!include "nsDialogs.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"

!define APP_NAME      "文件互传助手"
!define APP_VERSION   "1.2.0"
!define APP_VER4      "1.2.0.0"
!define APP_EXE       "ADBTypeLink.App.exe"
!define APP_KEY       "WifiAdbChatApp"
!define APP_UNINST    "Software\Microsoft\Windows\CurrentVersion\Uninstall\WifiAdbChatApp"

!define REPO_ROOT     "${__FILEDIR__}\..\.."
!define SRC_EXE       "${REPO_ROOT}\windows\publish\release-build\ADBTypeLink.App.exe"
!define SRC_ICON      "${REPO_ROOT}\windows\src\ADBTypeLink.App\Assets\app.ico"

Name "${APP_NAME}"
OutFile "${REPO_ROOT}\release\${APP_NAME}-${APP_VERSION}-安装包.exe"
InstallDir "$LOCALAPPDATA\Programs\${APP_NAME}"
InstallDirRegKey HKCU "Software\${APP_KEY}" "InstallDir"

VIProductVersion "${APP_VER4}"
VIAddVersionKey /LANG=2052 "ProductName"      "${APP_NAME}"
VIAddVersionKey /LANG=2052 "FileDescription"  "${APP_NAME} 安装程序"
VIAddVersionKey /LANG=2052 "FileVersion"      "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "ProductVersion"   "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "CompanyName"      "${APP_NAME}"
VIAddVersionKey /LANG=2052 "LegalCopyright"   "Copyright (c) ${APP_NAME}"

!define MUI_ABORTWARNING
!define MUI_ICON   "${SRC_ICON}"
!define MUI_UNICON "${SRC_ICON}"
!define MUI_WELCOMEPAGE_TITLE "欢迎安装 ${APP_NAME}"
!define MUI_WELCOMEPAGE_TEXT "本向导将引导你完成 ${APP_NAME} ${APP_VERSION} 的安装。$\r$\n$\r$\n${APP_NAME} 用于在局域网内把文字和文件直接传到手机，或在电脑之间像聊天一样互传，数据不经过任何服务器。$\r$\n$\r$\n点击「下一步」继续。"
!insertmacro MUI_PAGE_WELCOME
!define MUI_DIRECTORYPAGE_TEXT_TOP "请选择 ${APP_NAME} 的安装位置。点击「安装」开始复制文件。"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_TITLE "安装完成"
!define MUI_FINISHPAGE_TEXT "${APP_NAME} ${APP_VERSION} 已安装完成。$\r$\n$\r$\n点击「完成」退出安装向导。"
!define MUI_PAGE_CUSTOMFUNCTION_SHOW  FinishPageShow
!define MUI_PAGE_CUSTOMFUNCTION_LEAVE FinishPageLeave
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"

ShowInstDetails nevershow
ShowUninstDetails nevershow
BrandingText "${APP_NAME} ${APP_VERSION}"
XPStyle on

Var ShortcutCheck
Var RunCheck
Var FinishUiReady

; 目标程序是否正在运行（运行中无法覆盖/删除 exe，提前提示）
!macro IsAppLocked RESULT
  StrCpy ${RESULT} 0
  ${If} ${FileExists} "$INSTDIR\${APP_EXE}"
    ClearErrors
    FileOpen $9 "$INSTDIR\${APP_EXE}" a
    ${If} ${Errors}
      StrCpy ${RESULT} 1
    ${Else}
      FileClose $9
    ${EndIf}
  ${EndIf}
!macroend

Function .onInit
  !insertmacro IsAppLocked $0
  ${If} $0 == 1
    MessageBox MB_ICONSTOP|MB_OK "${APP_NAME} 正在运行。$\r$\n$\r$\n请先退出程序（可从任务栏右键退出），再重新运行安装包。"
    Abort
  ${EndIf}
FunctionEnd

Function un.onInit
  !insertmacro IsAppLocked $0
  ${If} $0 == 1
    MessageBox MB_ICONSTOP|MB_OK "${APP_NAME} 正在运行。$\r$\n$\r$\n请先退出程序，再重新运行卸载程序。"
    Abort
  ${EndIf}
FunctionEnd

Function FinishPageShow
  ; 完成页不需要「上一步」
  GetDlgItem $0 $HWNDPARENT 3
  ShowWindow $0 ${SW_HIDE}

  ${If} $FinishUiReady == 1
    Return
  ${EndIf}
  StrCpy $FinishUiReady 1

  ; 完成页上的两个选项：创建桌面快捷方式 / 立即运行
  ${NSD_CreateCheckbox} 120u 100u 200u 12u "创建桌面快捷方式"
  Pop $ShortcutCheck
  ${NSD_Check} $ShortcutCheck

  ${NSD_CreateCheckbox} 120u 118u 200u 12u "立即运行 ${APP_NAME}"
  Pop $RunCheck
  ${NSD_Check} $RunCheck
FunctionEnd

Function FinishPageLeave
  ${NSD_GetState} $ShortcutCheck $0
  ${If} $0 == ${BST_CHECKED}
    CreateShortCut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}" "" "$INSTDIR\app.ico" 0 SW_SHOWNORMAL
  ${EndIf}

  ${NSD_GetState} $RunCheck $0
  ${If} $0 == ${BST_CHECKED}
    Exec '"$INSTDIR\${APP_EXE}"'
  ${EndIf}
FunctionEnd

Section "主程序" SecMain
  SectionIn RO
  SetOutPath "$INSTDIR"
  File "${SRC_EXE}"
  File "/oname=app.ico" "${SRC_ICON}"
  WriteUninstaller "$INSTDIR\uninst.exe"

  ; 开始菜单
  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortCut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}" "" "$INSTDIR\app.ico" 0
  CreateShortCut "$SMPROGRAMS\${APP_NAME}\卸载 ${APP_NAME}.lnk" "$INSTDIR\uninst.exe"

  ; 静默安装时按默认选项一并创建桌面快捷方式
  ${If} ${Silent}
    CreateShortCut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}" "" "$INSTDIR\app.ico" 0 SW_SHOWNORMAL
  ${EndIf}

  ; 安装目录与卸载信息（当前用户，不需要管理员权限）
  WriteRegStr HKCU "Software\${APP_KEY}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\${APP_KEY}" "Version" "${APP_VERSION}"
  WriteRegStr HKCU "${APP_UNINST}" "DisplayName"     "${APP_NAME}"
  WriteRegStr HKCU "${APP_UNINST}" "DisplayVersion"  "${APP_VERSION}"
  WriteRegStr HKCU "${APP_UNINST}" "Publisher"       "${APP_NAME}"
  WriteRegStr HKCU "${APP_UNINST}" "DisplayIcon"     "$INSTDIR\app.ico"
  WriteRegStr HKCU "${APP_UNINST}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${APP_UNINST}" "UninstallString" '"$INSTDIR\uninst.exe"'
  WriteRegStr HKCU "${APP_UNINST}" "QuietUninstallString" '"$INSTDIR\uninst.exe" /S'
  WriteRegDWORD HKCU "${APP_UNINST}" "NoModify" 1
  WriteRegDWORD HKCU "${APP_UNINST}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "${APP_UNINST}" "EstimatedSize" "$0"
SectionEnd

Section "Uninstall"
  Delete "$DESKTOP\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\卸载 ${APP_NAME}.lnk"
  RMDir  "$SMPROGRAMS\${APP_NAME}"

  Delete "$INSTDIR\${APP_EXE}"
  Delete "$INSTDIR\app.ico"
  Delete "$INSTDIR\uninst.exe"
  RMDir  "$INSTDIR"

  DeleteRegKey HKCU "${APP_UNINST}"
  DeleteRegKey HKCU "Software\${APP_KEY}"
SectionEnd
