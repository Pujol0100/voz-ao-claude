#Requires -Version 5.1
<#
    Escutador de atalhos globais da Clarisse.

    Roda oculto e residente, uma instancia por maquina. Precisa ser um processo
    a parte porque atalho global no Windows so funciona com alguem bombeando a
    fila de mensagens do thread - e isso o terminal do Claude Code nao faz.

    Sobe sozinho no inicio de cada sessao (hook SessionStart).
    Encerra com: clarisse.ps1 -Mode atalhos-off
#>
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'nucleo.ps1')

Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ClarisseHotkeys {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG {
        public IntPtr hwnd;
        public uint   message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint   time;
        public int    pt_x;
        public int    pt_y;
    }

    [DllImport("user32.dll")]
    public static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint min, uint max);
}
'@

$WM_HOTKEY = 0x0312

$cfg = Get-Config
if (-not $cfg.atalhos) {
    Write-Log 'config sem bloco de atalhos - encerrando'
    exit 1
}

$mapa = @(
    @{ id = 1; combo = [string]$cfg.atalhos.ler },
    @{ id = 2; combo = [string]$cfg.atalhos.pausar },
    @{ id = 3; combo = [string]$cfg.atalhos.cancelar },
    @{ id = 4; combo = [string]$cfg.atalhos.pular }
)

$registrados = @()
foreach ($item in $mapa) {
    $cod = ConvertTo-CodigoAtalho $item.combo
    if (-not $cod) {
        Write-Log "atalho invalido ignorado: '$($item.combo)'"
        continue
    }
    if ([ClarisseHotkeys]::RegisterHotKey([IntPtr]::Zero, $item.id, $cod.mod, $cod.vk)) {
        $registrados += $item
    } else {
        Write-Log "atalho $($item.combo) recusado pelo Windows - outro programa ja usa essa combinacao"
    }
}

if ($registrados.Count -eq 0) {
    Write-Log 'nenhum atalho pode ser registrado - encerrando'
    exit 1
}

[System.IO.File]::WriteAllText($AtalhosPidPath, "$PID", $Utf8SemBom)
Write-Log "atalhos ativos: $(($registrados | ForEach-Object { $_.combo }) -join ', ')"

try {
    $msg = New-Object ClarisseHotkeys+MSG
    # GetMessage bloqueia ate chegar mensagem: laco sem consumo de CPU.
    while ([ClarisseHotkeys]::GetMessage([ref]$msg, [IntPtr]::Zero, 0, 0) -gt 0) {
        if ($msg.message -ne $WM_HOTKEY) { continue }
        # Cada acao aqui e so escrita de arquivo ou disparo de processo:
        # o laco nunca fica preso esperando o audio terminar.
        switch ($msg.wParam.ToInt32()) {
            # Ler e passear tem logica (triagem, selecao, consumo da fila), e ela
            # vive no clarisse.ps1, num lugar so. Pausar e cancelar sao escrita
            # de arquivo, rapidos o bastante para ficarem aqui.
            1 { Start-Modo 'ler' }
            2 { Switch-Pausa | Out-Null }
            3 { Stop-Fala | Out-Null }
            4 { Start-Modo 'proximo' }
        }
    }
} finally {
    foreach ($item in $registrados) {
        [void][ClarisseHotkeys]::UnregisterHotKey([IntPtr]::Zero, $item.id)
    }
    Remove-Item $AtalhosPidPath -Force -ErrorAction SilentlyContinue
}
