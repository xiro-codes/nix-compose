# Code Review Report

This document outlines code smells, anti-patterns, and suggestions for improvement across the Python and Nix codebase in the `nix-compose` repository.

## Python Code (`pkgs/nxc/nxc.py`)

### 1. Global Execution on Import
**Issue**: The configuration loading logic reading `NXC_CONFIG` from the environment and reading from disk is executed at module-level on import.
**Smell/Anti-pattern**: Doing I/O and modifying state globally at module level is an anti-pattern. If a user tries to import this script to reuse components (or during test execution), it will cause immediate side effects, potentially failing if environment variables or files are not set.
**Fix**: Move the configuration parsing into an initialization function `init_config()` and call it explicitly from the `main()` function.

### 2. Insecure Shell Argument Formatting
**Issue**: In `cmd_ssh`, arguments meant to be executed via `su -c` are built using string concatenation: `" ".join(command_args)`.
**Smell/Anti-pattern**: Shell Injection Vulnerability. Passing a user-provided string directly to a shell command (`su -c`) without properly escaping it can lead to executing arbitrary unexpected commands if `command_args` contains shell operators or spaces.
**Fix**: Use `shlex.join(command_args)` to properly quote and format the arguments.

### 3. Hardcoded Exits
**Issue**: `require_root()` and several missing parameter checks end with `sys.exit(1)`.
**Smell/Anti-pattern**: Hardcoded exits scatter control flow and make it difficult or impossible to write unit tests for those functions without mocking `sys.exit`.
**Fix**: While acceptable in small CLI tools, raising exceptions (e.g., `PermissionError` or a custom `CLIError`) and catching them in `main()` is more robust and testable.

### 4. Import Smells
**Issue**: The `shutil` module is imported at the top of the file but never used. Inside `cmd_up()`, the `os` module is imported again, even though it's already imported globally at the top.
**Smell/Anti-pattern**: Unnecessary imports clutter the namespace and duplicate imports are redundant.
**Fix**: Remove `import shutil` and the local `import os` inside `cmd_up()`.

## Nix Code (`lib/compose.nix`)

### 1. Potential Hash Collision
**Issue**: The `clusterHash` is calculated using `builtins.substring 0 4 (builtins.hashString "sha256" name)`.
**Smell/Anti-pattern**: Using only 4 characters of a sha256 hash for a cluster identifier drastically increases the chances of a hash collision. If a user spins up many clusters with different names that happen to collide on the first 4 hex characters, unexpected behavior could occur.
**Fix**: Add comments documenting this constraint to make developers aware, and potentially consider increasing the substring length if permissible by system limits.

### 2. Lack of Explicit Documentation / Comments
**Issue**: The `mkDevModule` and `mkCompose` functions contain some complex setup, particularly around container name hashing (`nc-${hash}`) to fit veth limits and the allocation of ssh ports (`2222`).
**Smell/Anti-pattern**: Unexplained "magic numbers" or hard limitations in logic (such as max 11 chars due to veth).
**Fix**: Add inline comments detailing why specific hash length limits are used, and document how `mkDevModule` integrates with node modules.

### 3. Hardcoded SSH Port Default
**Issue**: In the ssh port assignment logic, `sshPort = ... or 2222` is hardcoded deeply inside `evaluate` instead of being an explicitly defined default parameter on the interface or clearly documented.
**Fix**: Make sure it is properly commented, or eventually promote it to an explicit parameter in the `mkCompose` signature.
