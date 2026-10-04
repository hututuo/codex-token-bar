; A failed payload write must abort, never allow Ignore or silently skip.
; Both /UPDATE and manual installs run the same payload-copy policy.
AllowSkipFiles off
!macro NSIS_HOOK_PREINSTALL
  SetOverwrite on
!macroend

; Repair existing canonical product shortcuts after success; respect /NS.
!macro NSIS_HOOK_POSTINSTALL
  ${If} $UpdateMode = 1
  ${AndIf} $NoShortcutMode != 1
    !if "${STARTMENUFOLDER}" != ""
      ${If} ${FileExists} "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk"
        CreateShortcut "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
        !insertmacro SetLnkAppUserModelId "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk"
      ${EndIf}
    !else
      ${If} ${FileExists} "$SMPROGRAMS\${PRODUCTNAME}.lnk"
        CreateShortcut "$SMPROGRAMS\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
        !insertmacro SetLnkAppUserModelId "$SMPROGRAMS\${PRODUCTNAME}.lnk"
      ${EndIf}
    !endif
    ${If} ${FileExists} "$DESKTOP\${PRODUCTNAME}.lnk"
      CreateShortcut "$DESKTOP\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
      !insertmacro SetLnkAppUserModelId "$DESKTOP\${PRODUCTNAME}.lnk"
    ${EndIf}
  ${EndIf}
!macroend
