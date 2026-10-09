#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Prerequis Active Directory pour Apache Guacamole.
    Cree le compte de service et les groupes de securite.

.DESCRIPTION
    - Compte de service : s_guacamole (lecture seule LDAP)
    - Groupes :
        GRP_Guac_Admins  -> Administration Guacamole
        GRP_Guac_DC1     -> Acces RDP a dc1 (192.168.0.100)
        GRP_Guac_K3S1    -> Acces SSH a k3s-node-1 (192.168.0.11)

.NOTES
    Executer sur un controleur de domaine ou un poste avec RSAT.
    Domaine : corp.lcl
#>

$ErrorActionPreference = "Stop"

# ============================================================
# Variables
# ============================================================
$Domain           = "corp.lcl"
$ServiceAccountOU = "OU=service_accounts,OU=CORP,DC=corp,DC=lcl"
$GroupOU           = "OU=Technical,OU=groups,OU=CORP,DC=corp,DC=lcl"

$ServiceAccountName     = "s_guacamole"
$ServiceAccountPassword = "YcJVZOpl8boCDn9C2M2o"
$ServiceAccountUPN      = "$ServiceAccountName@$Domain"

$Groups = @(
    @{
        Name        = "GRP_Guac_Admins"
        Description = "Guacamole - Administrateurs (acces complet + gestion)"
    },
    @{
        Name        = "GRP_Guac_DC1"
        Description = "Guacamole - Acces RDP a dc1 (192.168.0.100)"
    },
    @{
        Name        = "GRP_Guac_K3S1"
        Description = "Guacamole - Acces SSH a k3s-node-1 (192.168.0.11)"
    }
)

# ============================================================
# Verification des OU
# ============================================================
Write-Host "=== Verification des OU ===" -ForegroundColor Cyan

foreach ($OU in @($ServiceAccountOU, $GroupOU)) {
    try {
        Get-ADOrganizationalUnit -Identity $OU | Out-Null
        Write-Host "[OK] OU existe : $OU" -ForegroundColor Green
    }
    catch {
        Write-Host "[ERREUR] OU introuvable : $OU" -ForegroundColor Red
        Write-Host "Creez l'OU avant de relancer ce script." -ForegroundColor Yellow
        exit 1
    }
}

# ============================================================
# Compte de service : s_guacamole
# ============================================================
Write-Host "`n=== Compte de service ===" -ForegroundColor Cyan

$ExistingAccount = Get-ADUser -Filter "SamAccountName -eq '$ServiceAccountName'" -ErrorAction SilentlyContinue

if ($ExistingAccount) {
    Write-Host "[SKIP] Le compte '$ServiceAccountName' existe deja." -ForegroundColor Yellow
}
else {
    $SecurePassword = ConvertTo-SecureString $ServiceAccountPassword -AsPlainText -Force

    New-ADUser `
        -Name $ServiceAccountName `
        -SamAccountName $ServiceAccountName `
        -UserPrincipalName $ServiceAccountUPN `
        -DisplayName "Guacamole Service Account" `
        -Description "Compte de service pour Apache Guacamole (requetes LDAP)" `
        -Path $ServiceAccountOU `
        -AccountPassword $SecurePassword `
        -Enabled $true `
        -PasswordNeverExpires $true `
        -CannotChangePassword $true `
        -ChangePasswordAtLogon $false

    Write-Host "[OK] Compte cree : $ServiceAccountName" -ForegroundColor Green
    Write-Host "     UPN      : $ServiceAccountUPN" -ForegroundColor Gray
    Write-Host "     OU       : $ServiceAccountOU" -ForegroundColor Gray
    Write-Host "     Password : $ServiceAccountPassword" -ForegroundColor Gray
}

# ============================================================
# Groupes de securite
# ============================================================
Write-Host "`n=== Groupes de securite ===" -ForegroundColor Cyan

foreach ($Group in $Groups) {
    $ExistingGroup = Get-ADGroup -Filter "Name -eq '$($Group.Name)'" -ErrorAction SilentlyContinue

    if ($ExistingGroup) {
        Write-Host "[SKIP] Le groupe '$($Group.Name)' existe deja." -ForegroundColor Yellow
    }
    else {
        New-ADGroup `
            -Name $Group.Name `
            -SamAccountName $Group.Name `
            -GroupCategory Security `
            -GroupScope Global `
            -DisplayName $Group.Name `
            -Description $Group.Description `
            -Path $GroupOU

        Write-Host "[OK] Groupe cree : $($Group.Name)" -ForegroundColor Green
        Write-Host "     Description : $($Group.Description)" -ForegroundColor Gray
    }
}

# ============================================================
# Resume
# ============================================================
Write-Host "`n=== Resume ===" -ForegroundColor Cyan
Write-Host "Compte de service :" -ForegroundColor White
Write-Host "  CN=s_guacamole,$ServiceAccountOU" -ForegroundColor Gray
Write-Host ""
Write-Host "Groupes (a peupler avec vos utilisateurs) :" -ForegroundColor White
foreach ($Group in $Groups) {
    Write-Host "  CN=$($Group.Name),$GroupOU" -ForegroundColor Gray
}
Write-Host ""
Write-Host "Prochaines etapes :" -ForegroundColor Yellow
Write-Host "  1. Ajouter les utilisateurs dans les groupes AD ci-dessus"
Write-Host "  2. Deployer Guacamole dans k3s : ansible-playbook playbooks/guacamole.yml"
Write-Host "  3. Acceder a https://guacamole.app.xixtu.eu/guacamole/"
Write-Host ""
