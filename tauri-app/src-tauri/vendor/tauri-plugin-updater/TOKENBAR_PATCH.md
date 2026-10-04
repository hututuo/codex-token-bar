# Local Windows launch fix

Base: crates.io tauri-plugin-updater 2.10.1, unchanged dependencies and licenses.
Only Windows install_inner changes: check ShellExecuteW's <=32 failure return,
and run Tauri cleanup only after a successful launch. No download or signature
verification changes. Startup failure returns to the caller without exiting.
The upstream 2.11.0 launch check has the same return criterion, but runs cleanup
before attempting launch; this patch also preserves the live app on failure.
