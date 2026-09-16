#
# PSScriptAnalyzer configuration. Used by .github/workflows/tests.yml and by
# anyone running the analyzer locally:
#
#   Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
#
# Every exclusion below is deliberate and explained. Prefer fixing a finding,
# or suppressing it at the single site with a justified
# [Diagnostics.CodeAnalysis.SuppressMessageAttribute], over adding to this list.
#
@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # These scripts are console-report tools: the color-coded PASS/WARN/FAIL
        # stream is the primary output, not incidental logging, and it is
        # deliberately not on the success stream so it cannot be captured or
        # piped into the report data. Write-Host is the right call here.
        'PSAvoidUsingWriteHost'

        # Fires on two patterns that are both correct:
        #   - the RemoteCertificateValidationCallback in the health check, whose
        #     four parameters are fixed by the delegate signature even though it
        #     accepts every certificate by design
        #   - the PowerCLI test stub, whose parameters exist so calls bind the
        #     same way they would against the real cmdlets
        'PSReviewUnusedParameter'
    )
}
