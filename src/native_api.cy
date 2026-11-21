// Small native package surface used by embedding hosts that do not want the
// HAO C ABI. Runtime work remains available through src/api.cy.
pub fn api_version(): u32 {
    return 1;
}
