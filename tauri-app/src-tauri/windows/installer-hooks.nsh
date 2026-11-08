; A failed payload write must abort, never allow Ignore or silently skip.
AllowSkipFiles off
!include "Win\COM.nsh"
!include "FileFunc.nsh"

Var TokenBarDiagnosticFile
Var TokenBarDiagnosticSession
Var TokenBarDiagnosticSequence
; Fixed-schema receipts only. No install path, account, command line or text.
!macro TokenBarDiagnostic phase
  Push $0
  Push $1
  ${If} $TokenBarDiagnosticFile != ""
    IntOp $TokenBarDiagnosticSequence $TokenBarDiagnosticSequence + 1
    System::Call 'kernel32::GetSystemTimeAsFileTime(*l.r0)'
    System::Int64Op $0 - 116444736000000000
    Pop $1
    System::Int64Op $1 / 10000
    Pop $1
    FileWrite $TokenBarDiagnosticFile '{$\"schema$\":1,$\"session$\":$\"$TokenBarDiagnosticSession$\",$\"sequence$\":$TokenBarDiagnosticSequence,$\"at$\":$1,$\"area$\":$\"installer$\",$\"phase$\":$\"${phase}$\",$\"version$\":$\"${VERSION}$\",$\"build$\":$\"unknown$\",$\"metrics$\":{}}$\r$\n'
    ClearErrors
  ${EndIf}
  Pop $1
  Pop $0
!macroend

; Keep existing user launchers byte-for-byte, including proxy scripts, arguments,
; icons and working directories. Back up before upstream shortcut handling.
!macro TokenBarSaveShortcut path name
  ${If} ${FileExists} "${path}"
    ClearErrors
    CopyFiles /SILENT "${path}" "$PLUGINSDIR\tokenbar-${name}.lnk"
    ${If} ${Errors}
      Abort "Cannot preserve existing Token Bar shortcut"
    ${EndIf}
  ${EndIf}
!macroend

; Repair only plain product EXE links. Use SetPath, never recreate the link:
; all other link properties survive. Unknown/unreadable/custom links are untouched.
!macro TokenBarRestoreShortcut path name
  ${If} ${FileExists} "$PLUGINSDIR\tokenbar-${name}.lnk"
    ClearErrors
    CopyFiles /SILENT "$PLUGINSDIR\tokenbar-${name}.lnk" "${path}"
    ${If} ${Errors}
      Abort "Cannot restore existing Token Bar shortcut"
    ${EndIf}
    ${If} $NoShortcutMode != 1
      !insertmacro ComHlpr_CreateInProcInstance ${CLSID_ShellLink} ${IID_IShellLink} r0 ""
      ${If} $0 P<> 0
        ${IUnknown::QueryInterface} $0 '("${IID_IPersistFile}", .r1)'
        ${If} $1 P<> 0
          ${IPersistFile::Load} $1 '("${path}", ${STGM_READWRITE})i.r5'
          ${If} $5 >= 0
            ${IShellLink::GetPath} $0 '(w .r2, i ${NSIS_MAX_STRLEN}, p0, i 4)i.r5'
            ${If} $5 = 0
              ${GetFileName} "$2" $3
              ${If} $3 == "${MAINBINARYNAME}.exe"
              ${AndIf} $2 != "$INSTDIR\${MAINBINARYNAME}.exe"
                ${IShellLink::GetArguments} $0 '(w .r3, i ${NSIS_MAX_STRLEN})i.r5'
                ${If} $5 = 0
                ${AndIf} $3 == ""
                  ${IShellLink::GetWorkingDirectory} $0 '(w .r3, i ${NSIS_MAX_STRLEN})i.r5'
                  ${If} $5 = 0
                  ${AndIf} $3 == ""
                    ${IShellLink::SetPath} $0 '(w "$INSTDIR\${MAINBINARYNAME}.exe")i.r5'
                    ${If} $5 >= 0
                      ${IPersistFile::Save} $1 '("${path}",1)i.r5'
                      ${If} $5 < 0
                        Abort "Cannot repair Token Bar shortcut path"
                      ${EndIf}
                    ${EndIf}
                  ${EndIf}
                ${EndIf}
              ${EndIf}
            ${EndIf}
          ${EndIf}
          ${IUnknown::Release} $1 ""
        ${EndIf}
        ${IUnknown::Release} $0 ""
      ${EndIf}
    ${EndIf}
  ${EndIf}
!macroend

!macro NSIS_HOOK_PREINSTALL
  StrCpy $TokenBarDiagnosticFile ""
  StrCpy $TokenBarDiagnosticSequence 0
  System::Call 'ole32::CoCreateGuid(g .r0)i.r1'
  ${If} $1 = 0
    StrCpy $TokenBarDiagnosticSession $0
    CreateDirectory "$LOCALAPPDATA\CodexTokenBar\diagnostics\v1\installations"
    FileOpen $TokenBarDiagnosticFile "$LOCALAPPDATA\CodexTokenBar\diagnostics\v1\installations\install-$TokenBarDiagnosticSession.jsonl" w
    ${If} ${Errors}
      StrCpy $TokenBarDiagnosticFile ""
    ${EndIf}
    ClearErrors
  ${EndIf}
  !insertmacro TokenBarDiagnostic started
  SetOverwrite on
  InitPluginsDir
  !if "${STARTMENUFOLDER}" != ""
    !insertmacro TokenBarSaveShortcut "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk" "startmenu"
  !else
    !insertmacro TokenBarSaveShortcut "$SMPROGRAMS\${PRODUCTNAME}.lnk" "startmenu"
  !endif
  !insertmacro TokenBarSaveShortcut "$DESKTOP\${PRODUCTNAME}.lnk" "desktop"
!macroend

!macro NSIS_HOOK_POSTINSTALL
  !insertmacro TokenBarDiagnostic completed
  ${If} $TokenBarDiagnosticFile != ""
    FileClose $TokenBarDiagnosticFile
    StrCpy $TokenBarDiagnosticFile ""
  ${EndIf}
  ClearErrors
  !if "${STARTMENUFOLDER}" != ""
    !insertmacro TokenBarRestoreShortcut "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk" "startmenu"
  !else
    !insertmacro TokenBarRestoreShortcut "$SMPROGRAMS\${PRODUCTNAME}.lnk" "startmenu"
  !endif
  !insertmacro TokenBarRestoreShortcut "$DESKTOP\${PRODUCTNAME}.lnk" "desktop"
  ; Tauri's GUI Finish page runs after POSTINSTALL. Do not let its default
  ; desktop-shortcut checkbox overwrite the link that we just preserved.
  ${If} ${FileExists} "$PLUGINSDIR\tokenbar-desktop.lnk"
    StrCpy $NoShortcutMode 1
  ${EndIf}
!macroend
