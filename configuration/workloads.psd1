# Workloads: everything configure.ps1 applies (besides hardware profiles), one DSC v3
# configuration each in workloads\<name>.dsc.yaml. It applies the Enabled ones, each after the
# workloads it Requires, plus the Always ones. On the command line, -Workloads a,b applies exactly
# those (plus what they require) instead of Enabled, and -ExcludeWorkloads a,b leaves some out.
#
#   Description  one line, for people choosing
#   Requires     other workloads to apply first (e.g. Visual Studio before adding components to it)
#   Commands     commands that should be on PATH afterwards; checked at the end of the run
#   Always       applied whatever the selection, and can't be excluded
#
# DSC v3 calls each resource's set without testing first, so every resource must be idempotent on
# its own (the WindowsSetup.* ones check before acting).
@{
    Enabled   = @(
        # Windows
        'ssh', 'time', 'system', 'remote-desktop', 'explorer', 'taskbar', 'keyboard'
        # Tools
        'terminal', 'vscode', 'git', 'go', 'uv', 'shell', 'neovim', 'pty-harness'
        # Development stacks (mostly from microsoft/WindowsDeveloperConfig's src/Workloads)
        'dotnet', 'java', 'python', 'node', 'typescript', 'ruby', 'rust', 'powershell', 'winforms', 'winui'
    )

    Workloads = @{
        core             = @{ Always = $true; Requires = @(); Commands = @()
                              Description = "Windows PowerShell's execution policy RemoteSigned (for Scoop's shims)" }
        ssh              = @{ Requires = @(); Commands = @('ssh')
                              Description = 'OpenSSH client, and the ssh-agent service running' }
        time             = @{ Requires = @(); Commands = @()
                              Description = 'RTC in UTC; time service running and resyncing after sleep/reconnect' }
        system           = @{ Requires = @(); Commands = @()
                              Description = 'Developer Mode, Win32 long paths, inline sudo (Windows 11 24H2+)' }
        'remote-desktop' = @{ Requires = @(); Commands = @()
                              Description = 'Allow Remote Desktop connections (firewall rule left closed)' }
        explorer         = @{ Requires = @(); Commands = @()
                              Description = 'Hidden files and extensions shown, full path in title, opens to This PC, quiet Quick Access' }
        taskbar          = @{ Requires = @(); Commands = @()
                              Description = 'End Task in taskbar; no web search, highlights, Start recommendations or widgets' }
        keyboard         = @{ Requires = @(); Commands = @()
                              Description = 'Fastest key repeat; Caps Lock as Ctrl (after a restart)' }
        terminal         = @{ Requires = @(); Commands = @('wt')
                              Description = 'Windows Terminal' }
        vscode           = @{ Requires = @(); Commands = @('code')
                              Description = 'Visual Studio Code' }
        git              = @{ Requires = @('ssh', 'vscode', 'terminal'); Commands = @('git')
                              Description = 'Git for Windows, using Windows OpenSSH, VS Code as editor, a Terminal profile' }
        go               = @{ Requires = @(); Commands = @('go')
                              Description = 'Go, latest stable from go.dev' }
        uv               = @{ Requires = @(); Commands = @('uv')
                              Description = 'uv, the Python package and project manager' }
        shell            = @{ Requires = @(); Commands = @('fzf', 'fd', 'rg', 'bat', 'eza')
                              Description = 'Interactive PowerShell: profile.d loader, PSFzf (Ctrl+T/Ctrl+R), fzf/fd/rg/bat/eza via mise' }
        'pty-harness'    = @{ Requires = @(); Commands = @()
                              Description = "WebAssembly engine for the pty test harness (tools\PtyHarness)" }
        neovim           = @{ Requires = @('git', 'uv', 'node', 'ruby'); Commands = @('nvim', 'fzf', 'rg', 'fd', 'lazygit', 'tree-sitter', 'ast-grep', 'gcc')
                              Description = 'Prerequisites for LazyVim: CLI tools via mise, gcc, Nerd Font in Terminal, providers (python venv, npm, gem), lazy hererocks' }
        visualstudio     = @{ Requires = @(); Commands = @()
                              Description = 'Visual Studio 2026 Community' }
        dotnet           = @{ Requires = @(); Commands = @('dotnet')
                              Description = '.NET 10 SDK' }
        java             = @{ Requires = @(); Commands = @('java')
                              Description = 'Microsoft Build of OpenJDK 25' }
        python           = @{ Requires = @(); Commands = @('py')
                              Description = 'Python 3.14 with the py launcher; no Microsoft Store python/python3 aliases' }
        node             = @{ Requires = @(); Commands = @('node', 'npm')
                              Description = 'Node.js LTS (winget, machine-wide)' }
        typescript       = @{ Requires = @('node'); Commands = @('tsc')
                              Description = 'TypeScript compiler (tsc), global via npm' }
        ruby             = @{ Requires = @(); Commands = @('ruby', 'gem')
                              Description = 'Ruby 3.4 (RubyInstaller) with the MSYS2 devkit' }
        rust             = @{ Requires = @('visualstudio'); Commands = @('rustup', 'cargo', 'rustc')
                              Description = "rustup (stable), with Visual Studio's C++ workload for linking" }
        powershell       = @{ Requires = @('vscode'); Commands = @()
                              Description = 'PowerShell development in VS Code: extensions, PSScriptAnalyzer rules' }
        winforms         = @{ Requires = @('dotnet', 'visualstudio', 'system'); Commands = @('dotnet')
                              Description = "Visual Studio's .NET desktop workload" }
        winui            = @{ Requires = @('dotnet', 'visualstudio', 'system'); Commands = @('dotnet')
                              Description = 'WinUI 3 / Windows App SDK: Visual Studio components, winapp CLI, App Runtime' }
    }
}
