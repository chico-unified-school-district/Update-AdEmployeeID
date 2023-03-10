<#
 .Synopsis
 .DESCRIPTION
 .EXAMPLE
 .EXAMPLE
 .INPUTS
 .OUTPUTS
 .NOTES
#>
[cmdletbinding()]
param(
 [Alias('DCs')]
 [string[]]$DomainControllers,
 [Alias('ADCred')]
 [System.Management.Automation.PSCredential]$ActiveDirectoryCredential,
 [Alias('EmpServer')]
 [string]$EmpDBServer,
 [Alias('EmpDB')]
 [string]$EmpDatabase,
 [string]$EmpTable,
 [Alias('EmpCred')]
 [System.Management.Automation.PSCredential]$EmpDBCredential,
 [Alias('IntServer')]
 [string]$IntermediateSqlServer,
 [Alias('IntDB')]
 [string]$IntermediateDatabase,
 [string]$AccountsTable,
 [Alias('IntCred')]
 [System.Management.Automation.PSCredential]$IntermediateCredential,
 [Alias('wi')]
 [switch]$WhatIf
)

function Get-IntDBData ($table, $dbParams) {
 process {
  $sql = 'SELECT * FROM {0} WHERE status IS NULL;' -f $table
  $msg = @(
   $MyInvocation.MyCommand.Name
   $dbParams.Server
   $dbParams.Database
   $dbParams.Credential.Username
   $sql
  )
  Write-Verbose ('{0},[{1}-{2}] as [{3}],[{4}]' -f $msg)
  Invoke-Sqlcmd @dbParams -Query $sql
 }
}

function Get-EmpData ($dbParams, $table) {
 process {
  $sql = 'SELECT empId FROM {0} WHERE empId = {1};' -f $EmpTable, $_.employeeId
  $emp = Invoke-SqlCmd @empDBParams -Query $sql
  if (-not$emp) {
   $msg = $MyInvocation.MyCommand.Name, $_.employeeId, $_.emailWork, $_.emailHome, $sql
   Write-Error ('{0},EmpId [{1}] not found. EmailWork: [{2}],EmailHome: [{3}],[{4}]' -f $msg)
   return
  }
  $_
 }
}

function Get-ADObj {
 process {
  $adParams = @{
   # this filter allows for our 2 types of email address
   Filter     = "mail -eq `'{0}`' -or homepage -eq `'{0}`'" -f $_.emailWork
   Properties = 'employeeId', 'mail', 'homepage'
  }
  $obj = Get-ADUser @adParams
  if ($obj.count -gt 1) {
   Write-Error ('Multiple AD objects with email address [{0}]' -f $_.emailWork)
   return
  }
  $obj
 }
}

function New-PSObj {
 process {
  Write-Verbose ('{0}' -f $MyInvocation.MyCommand.Name)
  $obj = $_ | Get-ADObj
  if ($null -eq $obj) { return }
  # create object with AD ObjectGUID and Intermediate DB data
  [PSCustomObject]@{
   id         = $_.id
   employeeId = $_.employeeId
   guid       = $obj.ObjectGUID
   mail       = $_.emailWork
   fn         = $_.fn
   ln         = $_.ln
  }
 }
}

function Update-ADEmpId {
 process {
  $msg = $MyInvocation.MyCommand.Name, $_.employeeId, $_.mail
  Write-Host ('{0},[{1}],[{2}]' -f $msg) -Fore DarkYellow
  $setParams = @{
   Identity    = $_.guid
   EmployeeID  = $_.employeeId
   Confirm     = $false
   WhatIf      = $WhatIf
   ErrorAction = 'Stop'
  }
  Set-ADUser @setParams
  $_ | Add-Member -MemberType NoteProperty -Name status -Value success
  $_
 }
}

function Update-IntDB ($table, $dbParams) {
 process {
  $sql = "UPDATE {0} SET status = `'{1}`', dts = CURRENT_TIMESTAMP WHERE id = {2};" -f $table, $_.status, $_.id
  $msg = $MyInvocation.MyCommand.Name, $_.employeeId, $_.mail, $_.status, $sql
  Write-Host ('{0},[{1}],[{2}],[{3}],[{4}]' -f $msg) -Fore DarkYellow
  if (-not$WhatIf) { Invoke-SqlCmd @dbparams -Query $sql }
 }
}

# ==================================================================

# Imported Functions
. .\lib\Clear-SessionData.ps1
. .\lib\Load-Module.ps1
. .\lib\New-ADSession.ps1
. .\lib\Select-DomainController.ps1
. .\lib\Show-TestRun.ps1

$intDBparams = @{
 Server     = $IntermediateSqlServer
 Database   = $IntermediateDatabase
 Credential = $IntermediateCredential
}

$empDBParams = @{
 Server     = $EmpDBServer
 Database   = $EmpDatabase
 Credential = $EmpDBCredential
}

$stopTime = Get-Date "9:00pm"
$delay = 60
'Process looping every {0} seconds until {1}' -f $delay, $stopTime
do {
 Show-TestRun
 Clear-SessionData

 'SQLServer' | Load-Module


 $dc = Select-DomainController $DomainControllers
 New-ADSession -dc $dc -cmdlets 'Get-ADUser', 'Set-ADUser' -Cred $ActiveDirectoryCredential

 $intDBResults = Get-IntDBData $AccountsTable $intDBparams
 $opObjs = $intDBResults | Get-EmpData $empDBParams $EmpTable | New-PSObj
 $opObjs | Update-ADEmpId | Update-IntDB $AccountsTable $intDBparams

 Clear-SessionData
 Show-TestRun
 if (-not$WhatIf) {
  # Loop delay
  # $nextRun = (Get-Date).AddSeconds($delay)
  # 'Next Run: {0}' -f $nextRun
  Start-Sleep $delay
 }
} until ($WhatIf -or ((Get-Date) -ge $stopTime))

# ==================================================================