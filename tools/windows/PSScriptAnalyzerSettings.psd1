@{
    # Used by CI and by tests/Setup-ConquestDev.Tests.ps1. Any finding not excluded here fails the build.
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',                          # interactive console UX on purpose (coloured status lines)
        'PSReviewUnusedParameter',                        # script parameters are consumed inside Invoke-ConquestDev via script scope
        'PSUseSingularNouns',                             # naming style only
        'PSUseShouldProcessForStateChangingFunctions'     # every state change is already gated by explicit confirmations / CreateNew
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1', '7.0') }
    }
    IncludeRules = @('*')
}
