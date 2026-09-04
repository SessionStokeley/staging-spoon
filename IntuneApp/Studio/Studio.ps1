#Requires -Version 5.1
<#
    Studio.ps1

    Windows (WPF) front end for the interactive configuration generator.

    This is a thin layer. Every decision - analysis, model shape, validation,
    preview text, execution approval - is delegated to the same headless
    modules the console wizard uses, so both front ends always agree.

    Windows only: WPF is unavailable on other platforms. Use the console
    wizard (New-IntuneApp.ps1) elsewhere.
#>

Set-StrictMode -Version Latest

function Test-WpfAvailable {
    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { return $false }
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        Add-Type -AssemblyName PresentationCore -ErrorAction Stop
        Add-Type -AssemblyName WindowsBase -ErrorAction Stop
        return $true
    }
    catch { return $false }
}

$script:StudioXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Intune Application Packaging Studio"
        Height="820" Width="1120" WindowStartupLocation="CenterScreen">
  <Window.Resources>
    <Style TargetType="Label"><Setter Property="Margin" Value="0,6,0,0"/></Style>
    <Style TargetType="TextBox"><Setter Property="Margin" Value="0,2,0,4"/><Setter Property="Padding" Value="3"/></Style>
    <Style TargetType="Button"><Setter Property="Padding" Value="12,5"/><Setter Property="Margin" Value="4,0"/></Style>
    <Style TargetType="CheckBox"><Setter Property="Margin" Value="0,4,0,2"/></Style>
    <Style TargetType="RadioButton"><Setter Property="Margin" Value="0,3,12,2"/></Style>
  </Window.Resources>

  <DockPanel Margin="10">

    <!-- Installer selection -->
    <GroupBox DockPanel.Dock="Top" Header="1. Installer" Padding="8">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBox x:Name="TxtInstaller" Grid.Column="0" VerticalAlignment="Center"/>
        <Button  x:Name="BtnBrowse"  Grid.Column="1" Content="Browse..."/>
        <Button  x:Name="BtnAnalyze" Grid.Column="2" Content="Analyze"/>
      </Grid>
    </GroupBox>

    <!-- Action bar -->
    <Border DockPanel.Dock="Bottom" BorderThickness="0,1,0,0" BorderBrush="#DDD" Padding="0,8,0,0" Margin="0,8,0,0">
      <DockPanel>
        <TextBlock x:Name="TxtStatus" DockPanel.Dock="Left" VerticalAlignment="Center"
                   Text="Select an installer to begin." Foreground="#555"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="BtnOpen"     Content="Open Config..."/>
          <Button x:Name="BtnGenerate" Content="Generate Configuration"/>
          <Button x:Name="BtnSave"     Content="Save"/>
          <Button x:Name="BtnValidate" Content="Validate"/>
          <Button x:Name="BtnPreview"  Content="Preview"/>
          <Button x:Name="BtnRun"      Content="Run Configuration" Background="#FFF0C0"/>
          <Button x:Name="BtnBuild"    Content="Build .intunewin"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <TabControl x:Name="Tabs" Margin="0,8,0,0">

      <TabItem Header="Application">
        <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="12">
          <Label Content="Application name"/><TextBox x:Name="TxtAppName"/>
          <Label Content="Publisher"/><TextBox x:Name="TxtPublisher"/>
          <Label Content="Version"/><TextBox x:Name="TxtVersion"/>
          <Label Content="Architecture"/>
          <StackPanel Orientation="Horizontal">
            <RadioButton x:Name="RbArch64" Content="x64" GroupName="Arch" IsChecked="True"/>
            <RadioButton x:Name="RbArch86" Content="x86" GroupName="Arch"/>
            <RadioButton x:Name="RbArchArm" Content="ARM64" GroupName="Arch"/>
          </StackPanel>
          <Separator Margin="0,12"/>
          <Label Content="Analysis" FontWeight="Bold"/>
          <TextBox x:Name="TxtAnalysis" IsReadOnly="True" Height="240"
                   FontFamily="Consolas" VerticalScrollBarVisibility="Auto"
                   TextWrapping="NoWrap" HorizontalScrollBarVisibility="Auto" Background="#F7F7F7"/>
        </StackPanel></ScrollViewer>
      </TabItem>

      <TabItem Header="Install">
        <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="12">
          <Label Content="Installer type"/>
          <StackPanel Orientation="Horizontal">
            <RadioButton x:Name="RbTypeExe" Content="EXE" GroupName="InsType" IsChecked="True"/>
            <RadioButton x:Name="RbTypeMsi" Content="MSI" GroupName="InsType"/>
          </StackPanel>
          <Label Content="Installer file (inside Files\)"/><TextBox x:Name="TxtInsFile"/>
          <Label Content="Installation context"/>
          <StackPanel Orientation="Horizontal">
            <RadioButton x:Name="RbCtxSystem" Content="System / All Users" GroupName="Ctx" IsChecked="True"/>
            <RadioButton x:Name="RbCtxUser" Content="Current User" GroupName="Ctx"/>
          </StackPanel>
          <Label Content="Installation interface"/>
          <StackPanel Orientation="Horizontal">
            <RadioButton x:Name="RbUiSilent" Content="Silent" GroupName="Ui" IsChecked="True"/>
            <RadioButton x:Name="RbUiBasic" Content="Basic UI" GroupName="Ui"/>
            <RadioButton x:Name="RbUiInteractive" Content="Interactive" GroupName="Ui"/>
          </StackPanel>
          <Label Content="Install arguments"/><TextBox x:Name="TxtInsArgs" FontFamily="Consolas"/>
          <Label Content="Restart behavior"/>
          <StackPanel Orientation="Horizontal">
            <RadioButton x:Name="RbRstSuppress" Content="Suppress" GroupName="Rst" IsChecked="True"/>
            <RadioButton x:Name="RbRstAllow" Content="Allow" GroupName="Rst"/>
            <RadioButton x:Name="RbRstPrompt" Content="Prompt" GroupName="Rst"/>
          </StackPanel>
          <Label Content="Success exit codes (comma separated)"/><TextBox x:Name="TxtExitCodes"/>
        </StackPanel></ScrollViewer>
      </TabItem>

      <TabItem Header="Uninstall">
        <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="12">
          <Label Content="Uninstall method"/>
          <StackPanel Orientation="Horizontal">
            <RadioButton x:Name="RbUnExe" Content="EXE uninstaller" GroupName="UnType" IsChecked="True"/>
            <RadioButton x:Name="RbUnMsi" Content="MSI ProductCode" GroupName="UnType"/>
          </StackPanel>
          <Label Content="Uninstaller path or command"/><TextBox x:Name="TxtUnFile"/>
          <Label Content="Uninstall arguments"/><TextBox x:Name="TxtUnArgs" FontFamily="Consolas"/>
          <Label Content="MSI ProductCode"/><TextBox x:Name="TxtUnCode" FontFamily="Consolas"/>
          <TextBlock TextWrapping="Wrap" Foreground="#666" Margin="0,10,0,0"
                     Text="An absolute path is normally correct: the uninstaller lives with the installed application, not inside the package."/>
        </StackPanel></ScrollViewer>
      </TabItem>

      <TabItem Header="Detection">
        <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="12">
          <TextBlock TextWrapping="Wrap" Foreground="#666"
                     Text="Detection must describe the application itself. Never base it on PATH, shortcuts or environment variables."/>
          <Label Content="Detection method"/>
          <StackPanel Orientation="Horizontal">
            <RadioButton x:Name="RbDetFile" Content="File" GroupName="Det" IsChecked="True"/>
            <RadioButton x:Name="RbDetReg" Content="Registry" GroupName="Det"/>
            <RadioButton x:Name="RbDetMsi" Content="MSI" GroupName="Det"/>
            <RadioButton x:Name="RbDetCustom" Content="Custom" GroupName="Det"/>
          </StackPanel>
          <Label Content="Install directory"/><TextBox x:Name="TxtDetPath"/>
          <Label Content="Executable to detect"/><TextBox x:Name="TxtDetFile"/>
          <Label Content="Minimum version (optional)"/><TextBox x:Name="TxtDetVersion"/>
          <Separator Margin="0,10"/>
          <Label Content="Registry path"/><TextBox x:Name="TxtDetRegPath"/>
          <Label Content="Value name"/><TextBox x:Name="TxtDetRegValue"/>
          <Label Content="MSI ProductCode"/><TextBox x:Name="TxtDetCode" FontFamily="Consolas"/>
        </StackPanel></ScrollViewer>
      </TabItem>

      <TabItem Header="Environment and PATH">
        <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="12">
          <CheckBox x:Name="ChkEnvEnabled" Content="Enable command-line access (PATH) and environment variables"/>
          <Border Background="#FFF9E6" BorderBrush="#E8D9A0" BorderThickness="1" Padding="8" Margin="0,8">
            <StackPanel>
              <TextBlock FontWeight="Bold" Text="SYSTEM PATH"/>
              <TextBlock Text="Applies to all users. Requires administrator or SYSTEM rights." Foreground="#555"/>
              <TextBlock FontWeight="Bold" Text="USER PATH" Margin="0,6,0,0"/>
              <TextBlock TextWrapping="Wrap" Foreground="#555"
                         Text="Applies to one profile. Under a SYSTEM-context Intune install this writes only the Default profile, not every existing user."/>
            </StackPanel>
          </Border>
          <Label Content="PATH scope"/>
          <StackPanel Orientation="Horizontal">
            <RadioButton x:Name="RbPathSystem" Content="System" GroupName="PathScope" IsChecked="True"/>
            <RadioButton x:Name="RbPathUser" Content="User" GroupName="PathScope"/>
            <RadioButton x:Name="RbPathBoth" Content="Both" GroupName="PathScope"/>
          </StackPanel>
          <Label Content="PATH entries (one per line)"/>
          <TextBox x:Name="TxtPathEntries" Height="110" AcceptsReturn="True" FontFamily="Consolas"
                   VerticalScrollBarVisibility="Auto"/>
          <StackPanel Orientation="Horizontal" Margin="0,4">
            <Button x:Name="BtnDetectPaths" Content="Detect Paths"/>
            <Button x:Name="BtnTestCommand" Content="Test Command"/>
            <TextBox x:Name="TxtTestCommand" Width="260" VerticalAlignment="Center"/>
          </StackPanel>
          <CheckBox x:Name="ChkPathRemove" Content="Remove PATH entries during uninstall" IsChecked="True"/>
          <Label Content="Environment variables (NAME=VALUE, one per line)"/>
          <TextBox x:Name="TxtEnvVars" Height="90" AcceptsReturn="True" FontFamily="Consolas"
                   VerticalScrollBarVisibility="Auto"/>
          <StackPanel Orientation="Horizontal">
            <RadioButton x:Name="RbVarMachine" Content="Machine scope" GroupName="VarScope" IsChecked="True"/>
            <RadioButton x:Name="RbVarUser" Content="User scope" GroupName="VarScope"/>
          </StackPanel>
        </StackPanel></ScrollViewer>
      </TabItem>

      <TabItem Header="Windows Integration">
        <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="12">
          <TextBlock TextWrapping="Wrap" Foreground="#666" Margin="0,0,0,8"
                     Text="These choices are recorded in the configuration for review and hand-off. The installer itself normally creates them; the packaging engine does not apply this section."/>
          <CheckBox x:Name="ChkWiEnabled" Content="Record Windows integration settings"/>
          <Separator Margin="0,8"/>
          <CheckBox x:Name="ChkStartMenu" Content="Start Menu shortcut"/>
          <Label Content="Name"/><TextBox x:Name="TxtSmName"/>
          <Label Content="Target"/><TextBox x:Name="TxtSmTarget"/>
          <CheckBox x:Name="ChkDesktop" Content="Desktop shortcut" Margin="0,10,0,2"/>
          <Label Content="Name"/><TextBox x:Name="TxtDtName"/>
          <Label Content="Target"/><TextBox x:Name="TxtDtTarget"/>
          <Separator Margin="0,10"/>
          <CheckBox x:Name="ChkAssoc" Content="File associations"/>
          <TextBlock Foreground="#666" TextWrapping="Wrap"
                     Text="Registering an association does not force the Windows default app; the user still confirms any change."/>
          <Label Content="Extensions (one per line, e.g. .rvt)"/>
          <TextBox x:Name="TxtAssoc" Height="70" AcceptsReturn="True" FontFamily="Consolas"/>
          <Separator Margin="0,10"/>
          <CheckBox x:Name="ChkServices" Content="Services"/>
          <Label Content="Service names (one per line)"/>
          <TextBox x:Name="TxtServices" Height="60" AcceptsReturn="True" FontFamily="Consolas"/>
          <CheckBox x:Name="ChkTasks" Content="Scheduled tasks" Margin="0,10,0,2"/>
          <Label Content="Task names (one per line)"/>
          <TextBox x:Name="TxtTasks" Height="60" AcceptsReturn="True" FontFamily="Consolas"/>
        </StackPanel></ScrollViewer>
      </TabItem>

      <TabItem Header="Configuration (.psd1)">
        <DockPanel Margin="12">
          <TextBlock DockPanel.Dock="Top" TextWrapping="Wrap" Foreground="#666" Margin="0,0,0,6"
                     Text="This is the actual file that drives the package. Edit it directly if you want; Save writes it to disk and Validate re-checks it."/>
          <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,6,0,0">
            <Button x:Name="BtnApplyText" Content="Apply edits to the form"/>
            <TextBlock x:Name="TxtConfigPath" VerticalAlignment="Center" Margin="12,0,0,0" Foreground="#555"/>
          </StackPanel>
          <TextBox x:Name="TxtPsd1" AcceptsReturn="True" AcceptsTab="True" FontFamily="Consolas" FontSize="12"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                   TextWrapping="NoWrap" Background="#FCFCFC"/>
        </DockPanel>
      </TabItem>

      <TabItem Header="Validation and Review">
        <DockPanel Margin="12">
          <TextBlock DockPanel.Dock="Top" Text="Validation" FontWeight="Bold"/>
          <TextBox x:Name="TxtValidation" DockPanel.Dock="Top" Height="230" IsReadOnly="True"
                   FontFamily="Consolas" VerticalScrollBarVisibility="Auto"
                   TextWrapping="NoWrap" HorizontalScrollBarVisibility="Auto" Background="#F7F7F7"/>
          <TextBlock DockPanel.Dock="Top" Text="Preview" FontWeight="Bold" Margin="0,10,0,0"/>
          <TextBox x:Name="TxtPreview" IsReadOnly="True" FontFamily="Consolas"
                   VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"
                   HorizontalScrollBarVisibility="Auto" Background="#F7F7F7"/>
        </DockPanel>
      </TabItem>

    </TabControl>
  </DockPanel>
</Window>
'@

function Show-PackagingStudio {
    <#
        .SYNOPSIS
        Launches the graphical configuration generator.

        .PARAMETER PackageRoot
        Package directory the configuration belongs to.

        .PARAMETER InstallerPath
        Optional installer to pre-load.

        .PARAMETER ConfigPath
        Optional existing configuration to open.
    #>
    param(
        [string]$PackageRoot = (Get-Location).Path,
        [string]$InstallerPath = '',
        [string]$ConfigPath = ''
    )

    if (-not (Test-WpfAvailable)) {
        throw 'The graphical Studio requires Windows with WPF. Use New-IntuneApp.ps1 for the console wizard.'
    }

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName System.Windows.Forms

    $reader = New-Object System.Xml.XmlNodeReader ([xml]$script:StudioXaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)

    # Bind every named element into a lookup.
    $ui = @{}
    foreach ($name in @(
        'TxtInstaller','BtnBrowse','BtnAnalyze','TxtStatus','BtnOpen','BtnGenerate','BtnSave',
        'BtnValidate','BtnPreview','BtnRun','BtnBuild','Tabs',
        'TxtAppName','TxtPublisher','TxtVersion','RbArch64','RbArch86','RbArchArm','TxtAnalysis',
        'RbTypeExe','RbTypeMsi','TxtInsFile','RbCtxSystem','RbCtxUser',
        'RbUiSilent','RbUiBasic','RbUiInteractive','TxtInsArgs',
        'RbRstSuppress','RbRstAllow','RbRstPrompt','TxtExitCodes',
        'RbUnExe','RbUnMsi','TxtUnFile','TxtUnArgs','TxtUnCode',
        'RbDetFile','RbDetReg','RbDetMsi','RbDetCustom','TxtDetPath','TxtDetFile','TxtDetVersion',
        'TxtDetRegPath','TxtDetRegValue','TxtDetCode',
        'ChkEnvEnabled','RbPathSystem','RbPathUser','RbPathBoth','TxtPathEntries',
        'BtnDetectPaths','BtnTestCommand','TxtTestCommand','ChkPathRemove','TxtEnvVars',
        'RbVarMachine','RbVarUser',
        'ChkWiEnabled','ChkStartMenu','TxtSmName','TxtSmTarget','ChkDesktop','TxtDtName','TxtDtTarget',
        'ChkAssoc','TxtAssoc','ChkServices','TxtServices','ChkTasks','TxtTasks',
        'TxtPsd1','BtnApplyText','TxtConfigPath','TxtValidation','TxtPreview'
    )) {
        $ui[$name] = $window.FindName($name)
    }

    # --- Shared state ------------------------------------------------------
    $state = [pscustomobject]@{
        Model       = (New-ConfigModel)
        Analysis    = $null
        ConfigPath  = if ($ConfigPath) { $ConfigPath } else { Join-Path $PackageRoot 'Configuration.psd1' }
        PackageRoot = $PackageRoot
    }

    function Set-Status {
        param([string]$Text, [string]$Color = '#555')
        $ui.TxtStatus.Text = $Text
        $ui.TxtStatus.Foreground = $Color
    }

    function Get-SelectedRadio {
        param([hashtable]$Map)   # control name -> value
        foreach ($name in $Map.Keys) {
            if ($ui[$name].IsChecked) { return $Map[$name] }
        }
        return ($Map.Values | Select-Object -First 1)
    }

    function Set-SelectedRadio {
        param([hashtable]$Map, [string]$Value)
        foreach ($name in $Map.Keys) {
            $ui[$name].IsChecked = ($Map[$name] -eq $Value)
        }
    }

    $archMap = @{ RbArch64 = 'x64'; RbArch86 = 'x86'; RbArchArm = 'ARM64' }
    $typeMap = @{ RbTypeExe = 'EXE'; RbTypeMsi = 'MSI' }
    $ctxMap  = @{ RbCtxSystem = 'System'; RbCtxUser = 'User' }
    $uiMap   = @{ RbUiSilent = 'Silent'; RbUiBasic = 'BasicUI'; RbUiInteractive = 'Interactive' }
    $rstMap  = @{ RbRstSuppress = 'Suppress'; RbRstAllow = 'Allow'; RbRstPrompt = 'Prompt' }
    $unMap   = @{ RbUnExe = 'EXE'; RbUnMsi = 'MSI' }
    $detMap  = @{ RbDetFile = 'File'; RbDetReg = 'Registry'; RbDetMsi = 'MSI'; RbDetCustom = 'Custom' }
    $varMap  = @{ RbVarMachine = 'Machine'; RbVarUser = 'User' }

    # --- Model <-> form ----------------------------------------------------
    function Write-FormFromModel {
        $m = $state.Model

        $ui.TxtAppName.Text   = [string]$m.ApplicationName
        $ui.TxtPublisher.Text = [string]$m.Publisher
        $ui.TxtVersion.Text   = [string]$m.Version
        Set-SelectedRadio $archMap ([string]$m.Architecture)

        Set-SelectedRadio $typeMap ([string]$m.Installer.Type)
        $ui.TxtInsFile.Text = [string]$m.Installer.File
        Set-SelectedRadio $ctxMap ([string]$m.Installer.Context)
        Set-SelectedRadio $uiMap  ([string]$m.Installer.UserInterface)
        $ui.TxtInsArgs.Text = [string]$m.Installer.Arguments
        Set-SelectedRadio $rstMap ([string]$m.Installer.Restart)
        $ui.TxtExitCodes.Text = (@($m.SuccessExitCodes) -join ', ')

        Set-SelectedRadio $unMap ([string]$m.Uninstaller.Type)
        $ui.TxtUnFile.Text = [string]$m.Uninstaller.File
        $ui.TxtUnArgs.Text = [string]$m.Uninstaller.Arguments
        $ui.TxtUnCode.Text = [string]$m.Uninstaller.ProductCode

        Set-SelectedRadio $detMap ([string]$m.Detection.Type)
        $ui.TxtDetPath.Text    = [string](Get-ModelValue $m 'Detection.Path')
        $ui.TxtDetFile.Text    = [string](Get-ModelValue $m 'Detection.FileName')
        $ui.TxtDetVersion.Text = [string](Get-ModelValue $m 'Detection.MinimumVersion')
        $ui.TxtDetRegPath.Text  = [string](Get-ModelValue $m 'Detection.RegistryPath')
        $ui.TxtDetRegValue.Text = [string](Get-ModelValue $m 'Detection.ValueName')
        $ui.TxtDetCode.Text     = [string](Get-ModelValue $m 'Detection.ProductCode')

        $ui.ChkEnvEnabled.IsChecked = [bool]$m.Environment.Enabled
        $sysOn = [bool]$m.Environment.SystemPath.Enabled
        $usrOn = [bool]$m.Environment.UserPath.Enabled
        $ui.RbPathBoth.IsChecked   = ($sysOn -and $usrOn)
        $ui.RbPathSystem.IsChecked = ($sysOn -and -not $usrOn)
        $ui.RbPathUser.IsChecked   = ($usrOn -and -not $sysOn)
        if (-not $sysOn -and -not $usrOn) { $ui.RbPathSystem.IsChecked = $true }

        $entries = if ($sysOn) { @($m.Environment.SystemPath.Entries) } else { @($m.Environment.UserPath.Entries) }
        $ui.TxtPathEntries.Text = ($entries -join [Environment]::NewLine)
        $ui.ChkPathRemove.IsChecked = [bool]$m.Environment.SystemPath.RemoveOnUninstall

        $ui.TxtEnvVars.Text = (@($m.Environment.Variables | ForEach-Object {
            if ($_ -is [System.Collections.IDictionary]) { "$($_['Name'])=$($_['Value'])" }
        }) -join [Environment]::NewLine)

        $wi = $m.WindowsIntegration
        $ui.ChkWiEnabled.IsChecked = [bool]$wi.Enabled
        $ui.ChkStartMenu.IsChecked = [bool]$wi.StartMenuShortcut.Enabled
        $ui.TxtSmName.Text   = [string]$wi.StartMenuShortcut.Name
        $ui.TxtSmTarget.Text = [string]$wi.StartMenuShortcut.Target
        $ui.ChkDesktop.IsChecked = [bool]$wi.DesktopShortcut.Enabled
        $ui.TxtDtName.Text   = [string]$wi.DesktopShortcut.Name
        $ui.TxtDtTarget.Text = [string]$wi.DesktopShortcut.Target
        $ui.ChkAssoc.IsChecked = [bool]$wi.FileAssociations.Enabled
        $ui.TxtAssoc.Text = (@($wi.FileAssociations.Associations | ForEach-Object {
            if ($_ -is [System.Collections.IDictionary]) { $_['Extension'] }
        }) -join [Environment]::NewLine)
        $ui.ChkServices.IsChecked = [bool]$wi.Services.Enabled
        $ui.TxtServices.Text = (@($wi.Services.Services | ForEach-Object {
            if ($_ -is [System.Collections.IDictionary]) { $_['Name'] }
        }) -join [Environment]::NewLine)
        $ui.ChkTasks.IsChecked = [bool]$wi.ScheduledTasks.Enabled
        $ui.TxtTasks.Text = (@($wi.ScheduledTasks.Tasks | ForEach-Object {
            if ($_ -is [System.Collections.IDictionary]) { $_['Name'] }
        }) -join [Environment]::NewLine)

        $ui.TxtConfigPath.Text = $state.ConfigPath
    }

    function Split-Lines {
        param([string]$Text)
        if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
        return @($Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    function Read-ModelFromForm {
        $m = $state.Model

        $m.ApplicationName = $ui.TxtAppName.Text
        $m.Publisher       = $ui.TxtPublisher.Text
        $m.Version         = $ui.TxtVersion.Text
        $m.Architecture    = Get-SelectedRadio $archMap

        $m.Installer.Type          = Get-SelectedRadio $typeMap
        $m.Installer.File          = $ui.TxtInsFile.Text
        $m.Installer.Context       = Get-SelectedRadio $ctxMap
        $m.Installer.UserInterface = Get-SelectedRadio $uiMap
        $m.Installer.Arguments     = $ui.TxtInsArgs.Text
        $m.Installer.Restart       = Get-SelectedRadio $rstMap
        $m.Intune.InstallBehavior  = $m.Installer.Context

        $codes = @()
        foreach ($part in ($ui.TxtExitCodes.Text -split ',')) {
            $n = 0
            if ([int]::TryParse($part.Trim(), [ref]$n)) { $codes += $n }
        }
        $m.SuccessExitCodes = $codes

        $m.Uninstaller.Type        = Get-SelectedRadio $unMap
        $m.Uninstaller.File        = $ui.TxtUnFile.Text
        $m.Uninstaller.Arguments   = $ui.TxtUnArgs.Text
        $m.Uninstaller.ProductCode = if ($ui.TxtUnCode.Text) { $ui.TxtUnCode.Text } else { $null }

        $m.Detection.Type = Get-SelectedRadio $detMap
        $m.Detection.Path           = $ui.TxtDetPath.Text
        $m.Detection.FileName       = $ui.TxtDetFile.Text
        $m.Detection.MinimumVersion = if ($ui.TxtDetVersion.Text) { $ui.TxtDetVersion.Text } else { $null }
        $m.Detection['RegistryPath'] = $ui.TxtDetRegPath.Text
        $m.Detection['ValueName']    = $ui.TxtDetRegValue.Text
        $m.Detection['ProductCode']  = $ui.TxtDetCode.Text

        # Environment
        $m.Environment.Enabled = [bool]$ui.ChkEnvEnabled.IsChecked
        $entries = Split-Lines $ui.TxtPathEntries.Text
        $scope = Get-SelectedRadio @{ RbPathSystem = 'System'; RbPathUser = 'User'; RbPathBoth = 'Both' }
        $remove = [bool]$ui.ChkPathRemove.IsChecked

        $m.Environment.SystemPath.Enabled = ($scope -in @('System', 'Both')) -and $entries.Count -gt 0
        $m.Environment.SystemPath.Entries = if ($m.Environment.SystemPath.Enabled) { $entries } else { @() }
        $m.Environment.SystemPath.RemoveOnUninstall = $remove

        $m.Environment.UserPath.Enabled = ($scope -in @('User', 'Both')) -and $entries.Count -gt 0
        $m.Environment.UserPath.Entries = if ($m.Environment.UserPath.Enabled) { $entries } else { @() }
        $m.Environment.UserPath.RemoveOnUninstall = $remove

        $varScope = Get-SelectedRadio $varMap
        $vars = @()
        foreach ($line in (Split-Lines $ui.TxtEnvVars.Text)) {
            $idx = $line.IndexOf('=')
            if ($idx -gt 0) {
                $vars += New-EnvironmentVariableEntry -Name $line.Substring(0, $idx).Trim() `
                    -Value $line.Substring($idx + 1).Trim() -Scope $varScope
            }
        }
        $m.Environment.Variables = $vars

        # Windows integration
        $wi = $m.WindowsIntegration
        $wi.Enabled = [bool]$ui.ChkWiEnabled.IsChecked
        $wi.StartMenuShortcut.Enabled = [bool]$ui.ChkStartMenu.IsChecked
        $wi.StartMenuShortcut.Name    = $ui.TxtSmName.Text
        $wi.StartMenuShortcut.Target  = $ui.TxtSmTarget.Text
        $wi.DesktopShortcut.Enabled   = [bool]$ui.ChkDesktop.IsChecked
        $wi.DesktopShortcut.Name      = $ui.TxtDtName.Text
        $wi.DesktopShortcut.Target    = $ui.TxtDtTarget.Text

        $wi.FileAssociations.Enabled = [bool]$ui.ChkAssoc.IsChecked
        $wi.FileAssociations.Associations = @(
            Split-Lines $ui.TxtAssoc.Text | ForEach-Object { New-FileAssociationEntry -Extension $_ }
        )
        $wi.Services.Enabled  = [bool]$ui.ChkServices.IsChecked
        $wi.Services.Services = @(Split-Lines $ui.TxtServices.Text | ForEach-Object { New-ServiceEntry -Name $_ })
        $wi.ScheduledTasks.Enabled = [bool]$ui.ChkTasks.IsChecked
        $wi.ScheduledTasks.Tasks   = @(Split-Lines $ui.TxtTasks.Text | ForEach-Object { New-ScheduledTaskEntry -Name $_ })

        return $m
    }

    function Update-Psd1Text {
        $model = Read-ModelFromForm
        $ui.TxtPsd1.Text = ConvertTo-Psd1String -InputObject $model -Comments (Get-ConfigurationComments)
    }

    function Update-Validation {
        $model = Read-ModelFromForm
        $findings = @(Test-ConfigModel -Model $model -PackageRoot $state.PackageRoot)
        $summary = Get-ValidationSummary -Findings $findings

        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine('Configuration Validation')
        [void]$sb.AppendLine(('-' * 58))
        if ($findings.Count -eq 0) { [void]$sb.AppendLine('  No findings.') }

        foreach ($grp in @(
            @{ S = 'Error'; G = '[X]' }, @{ S = 'Warning'; G = '[!]' }, @{ S = 'Information'; G = '[i]' }
        )) {
            foreach ($f in @($findings | Where-Object { $_.Severity -eq $grp.S })) {
                [void]$sb.AppendLine("  $($grp.G) [$($f.Category)] $($f.Message)")
                if ($f.Remedy) { [void]$sb.AppendLine("        -> $($f.Remedy)") }
            }
        }
        [void]$sb.AppendLine(('-' * 58))
        if ($summary.IsValid) {
            [void]$sb.AppendLine("Configuration is valid. $($summary.WarningCount) warning(s).")
        }
        else {
            [void]$sb.AppendLine("NOT valid. $($summary.ErrorCount) error(s) must be fixed.")
        }
        $ui.TxtValidation.Text = $sb.ToString()

        if ($summary.IsValid) { Set-Status 'Configuration is valid.' '#0A0' }
        else { Set-Status "$($summary.ErrorCount) error(s) - see Validation and Review." '#C00' }

        return $summary
    }

    function Update-Preview {
        $model = Read-ModelFromForm
        $preview = Get-ConfigurationPreview -Model $model
        $sb = [System.Text.StringBuilder]::new()
        foreach ($section in $preview.Keys) {
            [void]$sb.AppendLine($section)
            [void]$sb.AppendLine(('-' * $section.Length))
            foreach ($line in @($preview[$section])) { [void]$sb.AppendLine("  $line") }
            [void]$sb.AppendLine('')
        }
        $ui.TxtPreview.Text = $sb.ToString()
    }

    # --- Event handlers ----------------------------------------------------

    $ui.BtnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Installers (*.exe;*.msi)|*.exe;*.msi|All files (*.*)|*.*'
        if ($dlg.ShowDialog() -eq 'OK') { $ui.TxtInstaller.Text = $dlg.FileName }
    })

    $ui.BtnAnalyze.Add_Click({
        try {
            Set-Status 'Analyzing installer (reading metadata only)...'
            $analysis = Get-InstallerAnalysis -Path $ui.TxtInstaller.Text
            $state.Analysis = $analysis

            $lines = @(
                "File          : $($analysis.FileName)  ($($analysis.FileSizeText))"
                "Type          : $($analysis.InstallerType)"
                "Application   : $($analysis.ApplicationName)"
                "Publisher     : $($analysis.Publisher)"
                "Version       : $($analysis.Version)"
                "Architecture  : $($analysis.Architecture)"
                "Technology    : $($analysis.Technology)"
                "Confidence    : $($analysis.TechnologyConfidence)"
                "Silent args   : $($analysis.SilentArguments)"
                "ProductCode   : $($analysis.ProductCode)"
                "SHA256        : $($analysis.Sha256)"
                "Signature     : $($analysis.Signature.Status)"
                "Signer        : $($analysis.Signature.Signer)"
                ''
                'Recommendations'
                ('-' * 40)
            )
            foreach ($key in $analysis.Recommendations.Keys) {
                $rec = $analysis.Recommendations[$key]
                $lines += "$key (confidence: $($rec.Confidence))"
                $lines += "  $($rec.Reason)"
            }
            foreach ($n in @($analysis.Notes)) { $lines += "! $n" }
            $ui.TxtAnalysis.Text = ($lines -join [Environment]::NewLine)

            # Seed the form from the analysis.
            $ui.TxtAppName.Text   = $analysis.ApplicationName
            $ui.TxtPublisher.Text = $analysis.Publisher
            $ui.TxtVersion.Text   = $analysis.Version
            Set-SelectedRadio $archMap $analysis.Architecture
            Set-SelectedRadio $typeMap $analysis.InstallerType
            $ui.TxtInsFile.Text = $analysis.FileName
            $ui.TxtInsArgs.Text = $analysis.SilentArguments
            $ui.TxtExitCodes.Text = '0, 3010'

            $recDet = $analysis.Recommendations.Detection
            if ($recDet.Type -eq 'MSI') {
                Set-SelectedRadio $detMap 'MSI'
                $ui.TxtDetCode.Text = [string]$analysis.ProductCode
                Set-SelectedRadio $unMap 'MSI'
                $ui.TxtUnCode.Text = [string]$analysis.ProductCode
            }
            else {
                Set-SelectedRadio $detMap 'File'
                if ($recDet.Contains('Path')) { $ui.TxtDetPath.Text = [string]$recDet.Path }
                $ui.TxtUnArgs.Text = [string]$analysis.Recommendations.Uninstall.Arguments
            }

            Update-Psd1Text
            Set-Status 'Analysis complete. Nothing was installed or changed.' '#0A0'
        }
        catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, 'Analysis failed', 'OK', 'Error') | Out-Null
            Set-Status 'Analysis failed.' '#C00'
        }
    })

    $ui.BtnOpen.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Configuration (*.psd1)|*.psd1|All files (*.*)|*.*'
        if ($dlg.ShowDialog() -eq 'OK') {
            try {
                $state.Model = Import-ConfigModel -Path $dlg.FileName
                $state.ConfigPath = $dlg.FileName
                Write-FormFromModel
                Update-Psd1Text
                Update-Validation | Out-Null
                Update-Preview
                Set-Status "Opened $($dlg.FileName)" '#0A0'
            }
            catch {
                [System.Windows.MessageBox]::Show($_.Exception.Message, 'Could not open configuration', 'OK', 'Error') | Out-Null
            }
        }
    })

    $ui.BtnGenerate.Add_Click({
        Update-Psd1Text
        Update-Validation | Out-Null
        Update-Preview
        $ui.Tabs.SelectedIndex = 6   # Configuration (.psd1)
        Set-Status 'Configuration generated. Review it, then Save.' '#0A0'
    })

    $ui.BtnApplyText.Add_Click({
        # Parse the edited text back into the model so hand edits are not lost.
        $tmpFile = [System.IO.Path]::GetTempFileName() + '.psd1'
        try {
            [System.IO.File]::WriteAllText($tmpFile, $ui.TxtPsd1.Text, (New-Object System.Text.UTF8Encoding($false)))
            $syntax = Test-Psd1Syntax -Path $tmpFile
            if (-not $syntax.Valid) {
                [System.Windows.MessageBox]::Show(($syntax.Errors -join [Environment]::NewLine),
                    'The edited configuration does not parse', 'OK', 'Error') | Out-Null
                return
            }
            $state.Model = Import-ConfigModel -Path $tmpFile
            Write-FormFromModel
            Update-Validation | Out-Null
            Update-Preview
            Set-Status 'Edits applied to the form.' '#0A0'
        }
        catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, 'Could not apply edits', 'OK', 'Error') | Out-Null
        }
        finally { Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue }
    })

    $ui.BtnSave.Add_Click({
        try {
            $model = Read-ModelFromForm
            Export-ConfigurationFile -Model $model -Path $state.ConfigPath -Comments (Get-ConfigurationComments) | Out-Null
            $ui.TxtConfigPath.Text = $state.ConfigPath
            Update-Psd1Text
            Set-Status "Saved $($state.ConfigPath)" '#0A0'
        }
        catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, 'Save failed', 'OK', 'Error') | Out-Null
        }
    })

    $ui.BtnValidate.Add_Click({
        Update-Validation | Out-Null
        $ui.Tabs.SelectedIndex = 7
    })

    $ui.BtnPreview.Add_Click({
        Update-Preview
        $ui.Tabs.SelectedIndex = 7
    })

    $ui.BtnDetectPaths.Add_Click({
        $dir = $ui.TxtDetPath.Text
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) {
            [System.Windows.MessageBox]::Show(
                "The install directory does not exist on this machine yet:`n$dir`n`nInstall the application first, then detect paths.",
                'Detect Paths', 'OK', 'Information') | Out-Null
            return
        }
        if (-not (Get-Command Find-CliDirectories -ErrorAction SilentlyContinue)) {
            [System.Windows.MessageBox]::Show('CLI discovery helper is unavailable.', 'Detect Paths', 'OK', 'Warning') | Out-Null
            return
        }

        $found = Get-InstalledIntegrationCandidates -InstallPath $dir
        $candidates = @($found.PathCandidates)
        if ($candidates.Count -eq 0) {
            [System.Windows.MessageBox]::Show('No command-line directories were detected.', 'Detect Paths', 'OK', 'Information') | Out-Null
            return
        }

        # Present, do not auto-apply: high-confidence entries are proposed and
        # the technician confirms.
        $lines = foreach ($c in $candidates) {
            $exes = @($c.Executables | Where-Object { $_.IsCli } | ForEach-Object { $_.Name })
            "$($c.Directory)`n    confidence: $($c.Confidence); detected: $($exes -join ', ')"
        }
        $answer = [System.Windows.MessageBox]::Show(
            ("Detected:`n`n" + ($lines -join "`n`n") + "`n`nAdd the high-confidence directories to the PATH list?"),
            'Detect Paths', 'YesNo', 'Question')

        if ($answer -eq 'Yes') {
            $existing = Split-Lines $ui.TxtPathEntries.Text
            foreach ($c in $candidates) {
                if ($c.Confidence -eq 'High' -and $existing -notcontains $c.Directory) {
                    $existing += $c.Directory
                }
            }
            $ui.TxtPathEntries.Text = ($existing -join [Environment]::NewLine)
            $ui.ChkEnvEnabled.IsChecked = $true
        }
    })

    $ui.BtnTestCommand.Add_Click({
        $cmd = $ui.TxtTestCommand.Text
        if (-not $cmd) {
            [System.Windows.MessageBox]::Show('Enter a command to test, e.g. example-cli --version', 'Test Command', 'OK', 'Information') | Out-Null
            return
        }
        if (-not (Get-Command Test-CommandResolution -ErrorAction SilentlyContinue)) {
            [System.Windows.MessageBox]::Show('Command resolution helper is unavailable.', 'Test Command', 'OK', 'Warning') | Out-Null
            return
        }

        $exe = ($cmd -split ' ')[0]
        $res = Test-CommandResolution -Command $exe
        if ($res.Found) {
            [System.Windows.MessageBox]::Show(
                "PATH Resolution: PASS`nExecutable: $($res.Path)", 'Test Command', 'OK', 'Information') | Out-Null
        }
        else {
            [System.Windows.MessageBox]::Show(
                ("PATH Resolution: FAIL`n`nThe executable could not be resolved from PATH.`n`n" +
                 "Possible causes:`n" +
                 " - This session has a stale environment; reopen it after a PATH change.`n" +
                 " - The PATH entry was not registered.`n" +
                 " - The executable does not exist.`n" +
                 " - The PATH directory is wrong."),
                'Test Command', 'OK', 'Warning') | Out-Null
        }
    })

    $ui.BtnRun.Add_Click({
        $model = Read-ModelFromForm
        $summary = Update-Validation
        if (-not $summary.IsValid) {
            [System.Windows.MessageBox]::Show(
                'The configuration has errors and cannot be executed. Fix them first.',
                'Cannot run', 'OK', 'Error') | Out-Null
            $ui.Tabs.SelectedIndex = 7
            return
        }

        if (-not (Test-Path -LiteralPath $state.ConfigPath)) {
            [System.Windows.MessageBox]::Show('Save the configuration before running it.', 'Cannot run', 'OK', 'Warning') | Out-Null
            return
        }

        # Explicit approval, listing only the effects this configuration enables.
        $warning = Get-ExecutionWarningText -Model $model -ConfigPath $state.ConfigPath
        $text = "You are about to execute this configuration.`n`nThis may:`n" +
                (($warning.Effects | ForEach-Object { "  - $_" }) -join "`n") +
                "`n`nConfiguration:`n$($state.ConfigPath)`n`nContinue?"

        if ([System.Windows.MessageBox]::Show($text, 'Confirm execution', 'OKCancel', 'Warning') -ne 'OK') {
            Set-Status 'Cancelled. Nothing was executed.'
            return
        }

        try {
            Set-Status 'Running the configuration through the packaging engine...'
            $result = Test-PackageWorkflow -PackageRoot $state.PackageRoot
            $msg = if ($result.Success) { 'Package workflow passed.' } else { 'Package workflow failed - see the console output.' }
            [System.Windows.MessageBox]::Show($msg, 'Run Configuration', 'OK',
                $(if ($result.Success) { 'Information' } else { 'Error' })) | Out-Null
            Set-Status $msg $(if ($result.Success) { '#0A0' } else { '#C00' })
        }
        catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, 'Run failed', 'OK', 'Error') | Out-Null
        }
    })

    $ui.BtnBuild.Add_Click({
        $summary = Update-Validation
        if (-not $summary.IsValid) {
            [System.Windows.MessageBox]::Show('Fix the validation errors before building.', 'Cannot build', 'OK', 'Error') | Out-Null
            $ui.Tabs.SelectedIndex = 7
            return
        }
        try {
            $build = Build-IntunePackage -PackageRoot $state.PackageRoot
            if ($build.Success) {
                [System.Windows.MessageBox]::Show("Package built:`n$($build.Path)", 'Build', 'OK', 'Information') | Out-Null
                Set-Status "Built $($build.Path)" '#0A0'
            }
            else {
                [System.Windows.MessageBox]::Show("Build did not complete: $($build.Reason)", 'Build', 'OK', 'Warning') | Out-Null
            }
        }
        catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, 'Build failed', 'OK', 'Error') | Out-Null
        }
    })

    # --- Initial state -----------------------------------------------------
    if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
        $state.Model = Import-ConfigModel -Path $ConfigPath
    }
    if ($InstallerPath) { $ui.TxtInstaller.Text = $InstallerPath }

    Write-FormFromModel
    Update-Psd1Text

    $window.ShowDialog() | Out-Null
}
