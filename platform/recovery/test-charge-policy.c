#include <assert.h>
#include "mt6323-charge-policy.h"
int main(void) {
    unsigned checks=0, healthy=(1u<<5)|(1u<<6)|(1u<<4);
    assert(mt6323_recovery_current_code(&checks,healthy,3800000)==0xc);
    assert(mt6323_recovery_current_code(&checks,healthy,3800000)==0xc);
    assert(mt6323_recovery_current_code(&checks,healthy,3800000)==0x6);
    assert(mt6323_recovery_current_code(&checks,healthy,4000000)==0x6);
    unsigned faults[]={0,healthy&~(1u<<6),healthy|(1u<<7),healthy&~(1u<<4)};
    for(unsigned i=0;i<sizeof(faults)/sizeof(faults[0]);i++) {
        checks=3;assert(mt6323_recovery_current_code(&checks,faults[i],3800000)==0xc);assert(checks==0);
    }
    checks=3;assert(mt6323_recovery_current_code(&checks,healthy,-1)==0xc);assert(checks==0);
    checks=3;assert(mt6323_recovery_current_code(&checks,healthy,4150000)==0xc);assert(checks==0);
    return 0;
}
