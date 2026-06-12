## Note on submodule branches

`.gitmodules` declares `branch = feat/room-codes` for both submodules. Without it, `git submodule update --remote` would have followed `main`; now it follows `feat/room-codes`.

### Re-pinning to latest going forward
Two ways, depending on the situation:

After you commit + push inside a submodule (submodule stays on its branch — cleanest for active work):

```
git add localsend-server localsend-web
git commit -m "bump submodules to latest feat/room-codes"
```

Since each submodule's working tree is on `feat/room-codes`, `git add` records the new tip automatically.

To pull whatever's on the remote `feat/room-codes`:

```
git submodule update --remote --recursive
git add localsend-server localsend-web
git commit -m "bump submodules to latest feat/room-codes"
# if you want to keep working on the branch afterward:
git -C localsend-server checkout feat/room-codes
git -C localsend-web    checkout feat/room-codes
```