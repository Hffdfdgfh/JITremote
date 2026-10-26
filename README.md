# JITRemote
Enables JIT on a *different* iOS device over Wi-Fi (RemotePairing tunnel -> app service -> debug proxy).
Built on the idevice FFI and the ScriptRunner from StikJIT (MPL-2.0, see LICENSE-StikJIT-MPL2.txt).

Target device needs: Developer Mode on, Developer Disk Image mounted (once per boot), same Wi-Fi, app signed with get-task-allow.
Build: push to GitHub -> Actions -> download JITRemote-ipa -> sideload.
