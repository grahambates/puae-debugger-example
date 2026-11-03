        ifnd    MACROS_I
MACROS_I set    1


BLIT_WAIT macro
.\@:    btst    #DMAB_BLTDONE,dmaconr(a6)
        bne.s   .\@
        endm

        endc
