# ScheduledTask: an event-triggered scheduled task running a program as a built-in service
# account. (Replaces ComputerManagementDsc's ScheduledTask, which DSC v3 could only run through
# the Windows PowerShell adapter, with the module installed from the Gallery by hand.)

using module WindowsSetup.Common

# Collapses the whitespace Task Scheduler (or YAML folding) may add to an event query.
function ConvertTo-NormalizedXml([string] $Xml) {
    return (($Xml -replace '\s+', ' ') -replace '>\s+<', '><').Trim()
}

# How the registered task differs from the desired state; empty when it matches.
function Get-ScheduledTaskDrift($desired) {
    $task = Get-ScheduledTask -TaskPath $desired.TaskPath -TaskName $desired.TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        return @('the task is not registered')
    }
    $drift = @()
    $action = @($task.Actions)[0]
    if ($action.Execute -ne $desired.Execute) { $drift += "Execute: '$($action.Execute)'" }
    if ("$($action.Arguments)" -ne "$($desired.Arguments)") { $drift += "Arguments: '$($action.Arguments)'" }
    $trigger = @($task.Triggers)[0]
    if (-not $trigger -or $trigger.CimClass.CimClassName -ne 'MSFT_TaskEventTrigger') {
        $drift += 'the trigger is not an event trigger'
    } else {
        if ((ConvertTo-NormalizedXml $trigger.Subscription) -ne (ConvertTo-NormalizedXml $desired.EventSubscription)) { $drift += 'EventSubscription' }
        if ("$($trigger.Delay)" -ne "$($desired.Delay)") { $drift += "Delay: '$($trigger.Delay)'" }
    }
    if ($task.Principal.UserId -ne $desired.RunAs) { $drift += "RunAs: '$($task.Principal.UserId)'" }
    $settings = $task.Settings
    if ("$($settings.MultipleInstances)" -ne $desired.MultipleInstances) { $drift += "MultipleInstances: '$($settings.MultipleInstances)'" }
    if ("$($settings.ExecutionTimeLimit)" -ne "$($desired.ExecutionTimeLimit)") { $drift += "ExecutionTimeLimit: '$($settings.ExecutionTimeLimit)'" }
    if ($settings.DisallowStartIfOnBatteries -eq $desired.AllowStartIfOnBatteries) { $drift += 'AllowStartIfOnBatteries' }
    if ($settings.StopIfGoingOnBatteries -eq $desired.DontStopIfGoingOnBatteries) { $drift += 'DontStopIfGoingOnBatteries' }
    if ("$($task.Description)" -ne "$($desired.Description)") { $drift += 'Description' }
    return $drift
}

function Register-DesiredScheduledTask($desired) {
    $action = New-ScheduledTaskAction -Execute $desired.Execute -Argument $desired.Arguments
    # New-ScheduledTaskTrigger has no event triggers; build the CIM instance directly.
    $triggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
    $trigger = New-CimInstance -CimClass $triggerClass -ClientOnly
    $trigger.Enabled = $true
    $trigger.Subscription = $desired.EventSubscription
    if ($desired.Delay) { $trigger.Delay = $desired.Delay }
    $principal = New-ScheduledTaskPrincipal -UserId $desired.RunAs -LogonType ServiceAccount -RunLevel Highest
    $settingsArgs = @{
        MultipleInstances          = $desired.MultipleInstances
        AllowStartIfOnBatteries    = $desired.AllowStartIfOnBatteries
        DontStopIfGoingOnBatteries = $desired.DontStopIfGoingOnBatteries
    }
    if ($desired.ExecutionTimeLimit) {
        $settingsArgs.ExecutionTimeLimit = [System.Xml.XmlConvert]::ToTimeSpan($desired.ExecutionTimeLimit)
    }
    $settings = New-ScheduledTaskSettingsSet @settingsArgs
    Register-ScheduledTask -TaskPath $desired.TaskPath -TaskName $desired.TaskName -Description $desired.Description `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}

# A scheduled task started by an event (Task Scheduler's "On an event" trigger), e.g. network
# connected or resumed from sleep. Durations are ISO 8601, as Task Scheduler stores them (PT15S).
[DscResource()]
class ScheduledTask {
    # Task Scheduler folder, with a backslash at each end, e.g. \windows-setup\
    [DscProperty(Key)]
    [string] $TaskPath

    [DscProperty(Key)]
    [string] $TaskName

    [DscProperty()]
    [Ensure] $Ensure = [Ensure]::Present

    [DscProperty()]
    [string] $Description

    [DscProperty()]
    [string] $Execute

    [DscProperty()]
    [string] $Arguments

    # Event query XML (a <QueryList>), as Event Viewer's "Custom view" XML tab shows it.
    [DscProperty()]
    [string] $EventSubscription

    # How long after the event to start, e.g. PT15S.
    [DscProperty()]
    [string] $Delay

    [DscProperty()]
    [ValidateSet('SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE')]
    [string] $RunAs = 'SYSTEM'

    [DscProperty()]
    [ValidateSet('IgnoreNew', 'Parallel', 'Queue', 'StopExisting')]
    [string] $MultipleInstances = 'IgnoreNew'

    # e.g. PT5M
    [DscProperty()]
    [string] $ExecutionTimeLimit

    # Task Scheduler's defaults skip tasks on battery; laptops usually want both of these.
    [DscProperty()]
    [bool] $AllowStartIfOnBatteries

    [DscProperty()]
    [bool] $DontStopIfGoingOnBatteries

    [ScheduledTask] Get() {
        $current = [ScheduledTask]::new()
        $current.TaskPath = $this.TaskPath
        $current.TaskName = $this.TaskName
        $task = Get-ScheduledTask -TaskPath $this.TaskPath -TaskName $this.TaskName -ErrorAction SilentlyContinue
        if (-not $task) {
            $current.Ensure = [Ensure]::Absent
            return $current
        }
        $action = @($task.Actions)[0]
        $trigger = @($task.Triggers)[0]
        $current.Ensure = [Ensure]::Present
        $current.Description = $task.Description
        $current.Execute = $action.Execute
        $current.Arguments = $action.Arguments
        $current.EventSubscription = $trigger.Subscription
        $current.Delay = $trigger.Delay
        $current.ExecutionTimeLimit = $task.Settings.ExecutionTimeLimit
        $current.AllowStartIfOnBatteries = -not $task.Settings.DisallowStartIfOnBatteries
        $current.DontStopIfGoingOnBatteries = -not $task.Settings.StopIfGoingOnBatteries
        try { $current.RunAs = $task.Principal.UserId } catch { }
        try { $current.MultipleInstances = "$($task.Settings.MultipleInstances)" } catch { }
        return $current
    }

    [bool] Test() {
        if ($this.Ensure -eq [Ensure]::Absent) {
            return -not (Get-ScheduledTask -TaskPath $this.TaskPath -TaskName $this.TaskName -ErrorAction SilentlyContinue)
        }
        $drift = @(Get-ScheduledTaskDrift $this)
        $drift | ForEach-Object { Write-Verbose "Scheduled task $($this.TaskPath)$($this.TaskName): $_" }
        return $drift.Count -eq 0
    }

    [void] Set() {
        if ($this.Test()) { return }  # DSC v3 calls Set() without testing first
        if ($this.Ensure -eq [Ensure]::Absent) {
            Unregister-ScheduledTask -TaskPath $this.TaskPath -TaskName $this.TaskName -Confirm:$false
            return
        }
        Register-DesiredScheduledTask $this
    }
}
