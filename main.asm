        include "includes/hw.i"
        include "includes/macros.i"
        include "includes/startup.i"

********************************************************************************

POINT_COUNT = 8
PERSP_DIST = 300
PERSP_SHIFT = 8

FACE_COUNT = 6
CUBE_SIZE = 64

FP_BITS = 3
SubPixelBlitterEdgeLine_Mask = (1<<FP_BITS)-1

LINE_MINTERM = $4a      ; xor
; LINE_MINTERM	=	$ca		; or

SIN_LEN = 1024

FP2I14FP macro
        lsl.l   #2+FP_BITS,\1
        swap    \1
        endm

FP2I14  macro
        lsl.l   #2,\1
        swap    \1
        endm

FPMULS14 macro
        muls    \1,\2
        FP2I14  \2
        endm


; Dispaly setup:
BPLS = 3                ; Bitplane count
DIW_W = 224             ; Display window width
DIW_H = 224             ; Display window height
INTERLEAVED = 0         ; Interleaved bitplanes?
SCROLL = 0              ; Enable playfield scroll (add additional word of data fetch)
DPF = 0                 ; Enable dual playfield
HAM = 0                 ; Enable HAM
HIRES = 0               ; Enable hi-res mode
LACE = 0                ; Enable interlace
PF1P = 0                ; Playfield 1 priority code (with respect to sprites)
PF2P = 0                ; Playfield 2 priority code (with respect to sprites)
PF2PRI = 0              ; Playfield 2 (even planes) has priority over (appears in front of) playfield 1 (odd planes).

SCREEN_W = DIW_W        ; Screen buffer width
SCREEN_H = DIW_H        ; Screen buffer height

; Initial DMA/Interrupt bits:
DMASET = DMAF_SETCLR!DMAF_MASTER!DMAF_RASTER!DMAF_COPPER!DMAF_BLITTER
INTSET = INTF_SETCLR!INTF_INTEN!INTF_VERTB

;-------------------------------------------------------------------------------

COLORS = 1<<BPLS        ; Number of palette colours
SCREEN_BW = SCREEN_W/16*2 ; byte-width of 1 bitplane line
        ifne    INTERLEAVED
SCREEN_MOD = SCREEN_BW*(BPLS-1) ; modulo (interleaved)
SCREEN_BPL = SCREEN_BW  ; bitplane offset (interleaved)
        else
SCREEN_MOD = 0          ; modulo (non-interleaved)
SCREEN_BPL = SCREEN_BW*SCREEN_H ; bitplane offset (non-interleaved)
        endc
SCREEN_SIZE = SCREEN_BW*SCREEN_H*BPLS ; byte size of screen buffer
DIW_BW = DIW_W/16*2     ; Display window bit width
DIW_MOD = SCREEN_BW-DIW_BW+SCREEN_MOD-SCROLL*2
DIW_SIZE = DIW_BW*DIW_H*BPLS ; Display window byte size
DIW_LW = DIW_W/(HIRES+1) ; low res width

; Display windows bounds for centered PAL display:
DIW_XSTRT = $81+(320-DIW_LW)/2
DIW_YSTRT = $2c+(256-DIW_H)/2
DIW_XSTOP = DIW_XSTRT+DIW_LW
DIW_YSTOP = DIW_YSTRT+DIW_H


********************************************************************************
Entrypoint:
********************************************************************************
        move.l  #Interrupt,$6c(a4)
        move.w  #INTSET,intena(a6)
        bsr     WaitEOF
        move.l  #Cop,cop1lc(a6)
        move.w  #DMASET,dmacon(a6)

;-------------------------------------------------------------------------------
.mainLoop:
        move.w #DMAF_BLITHOG,dmacon(a6)
        move.l  DrawScreen,a0
        bsr     Clear
        bsr     Update
        bsr     Transform
        bsr     Draw

        move.w #DMAF_BLITHOG!DMAF_SETCLR,dmacon(a6)
        BLIT_WAIT
        bsr     SwapBuffers
        bsr     WaitEOF
        btst    #CIAB_GAMEPORT0,ciaa ; Left mouse button not pressed?
        bne     .mainLoop
        rts

********************************************************************************
Interrupt:
********************************************************************************
        movem.l d0-a6,-(sp)
        lea     custom,a6
        btst    #INTB_VERTB,intreqr+1(a6)
        beq.s   .notvb

        ; Vertical blank interrupt
        lea     Frame(pc),a0
        addq.w  #1,(a0)

        moveq   #INTF_VERTB,d0
        move.w  d0,intreq(a6)
        move.w  d0,intreq(a6)
.notvb: movem.l (sp)+,d0-a6
        rte


********************************************************************************
* Routines
********************************************************************************

********************************************************************************
Update:
        lea     Vars(pc),a5
        move.w  Frame(pc),d0
        move.w  #(SIN_LEN-1)*2,d4

        ; Z angle = frame * 4
        move.w  d0,d1
        lsl.w   #2,d1
        and.w   d4,d1
        ; Y angle = frame * 8
        move.w  d0,d2
        lsl.w   #3,d2
        and.w   d4,d2
        ; X angle = frame * 2
        move.w  d0,d3
        lsl.w   #1,d3
        and.w   d4,d3

        movem.w d1-d3,Rot-Vars(a5)
        rts


********************************************************************************
Transform:
        ; First, build the rotation matrix from the three angles
        bsr     BuildRotationMatrix

        ; Now transform all points using the matrix
        lea     Points,a0
        lea     PointsTransformed,a1
        move.w  #POINT_COUNT-1,d7
.l
        movem.w (a0)+,d4-d6

        ; Apply rotation matrix to a point
        ;-------------------------------------------------------------------------------
        lea     Matrix(pc),a2

        ; Calculate new x = m00*x + m01*y + m02*z
        move.w  (a2)+,d0
        muls    d4,d0   ; m00*x
        move.w  (a2)+,d1
        muls    d5,d1   ; m01*y
        add.l   d1,d0
        move.w  (a2)+,d1
        muls    d6,d1   ; m02*z
        add.l   d1,d0
        FP2I14FP d0     ; new x, convert to integer with extra precision

        ; Calculate new y = m10*x + m11*y + m12*z
        move.w  (a2)+,d1
        muls    d4,d1   ; m10*x
        move.w  (a2)+,d2
        muls    d5,d2   ; m11*y
        add.l   d2,d1
        move.w  (a2)+,d2
        muls    d6,d2   ; m12*z
        add.l   d2,d1
        FP2I14FP d1     ; new y, convert to integer with extra precision

        ; Calculate new z = m20*x + m21*y + m22*z
        move.w  (a2)+,d2
        muls    d4,d2   ; m20*x
        move.w  (a2)+,d3
        muls    d5,d3   ; m21*y
        add.l   d3,d2
        move.w  (a2)+,d3
        muls    d6,d3   ; m22*z
        add.l   d3,d2
        FP2I14  d2      ; new z, convert to integer

        ; Perspective projection
        ext.l   d0
        ext.l   d1
        add.w   #PERSP_DIST,d2
        asl.l   #PERSP_SHIFT,d0
        asl.l   #PERSP_SHIFT,d1
        divs    d2,d1
        divs    d2,d0

        ; Center in screen coordinates
        add.w   #(SCREEN_W/2)<<FP_BITS,d0
        add.w   #(SCREEN_H/2)<<FP_BITS,d1

        ; Write transformed data
        move.w  d0,(a1)+
        move.w  d1,(a1)+
        dbf     d7,.l

        rts


********************************************************************************
; BuildRotationMatrix - Calculates combined rotation matrix from XYZ angles
; Matrix = RotZ * RotX * RotY (applied in order: Y, then X, then Z)
; Using YXZ order (computer graphics standard)
;
; Matrix format (row-major):
;   m00 m01 m02
;   m10 m11 m12
;   m20 m21 m22
;-------------------------------------------------------------------------------
BuildRotationMatrix:
        lea     Matrix,a0
        lea     Sin,a1
        lea     Cos,a2
        movem.w Rot(pc),a3-a5 ; a3=ZRot, a4=YRot, a5=XRot

        move.w  (a1,a3),d0 ; sinZ
        move.w  (a2,a3),d1 ; cosZ
        move.w  (a1,a4),d2 ; sinY
        move.w  (a2,a4),d3 ; cosY
        move.w  (a1,a5),d4 ; sinX
        move.w  (a2,a5),d5 ; cosX

        ; Calculate combined rotation matrix elements for YXZ order
        ; m00 = cosY*cosZ - sinY*sinX*sinZ
        move.w  d3,d6
        FPMULS14 d1,d6  ; cosY*cosZ
        move.w  d2,d7
        FPMULS14 d4,d7  ; sinY*sinX
        FPMULS14 d0,d7  ; *sinZ
        sub.w   d7,d6
        move.w  d6,(a0)+

        ; m01 = -cosX*sinZ
        move.w  d5,d6
        FPMULS14 d0,d6
        neg.w   d6
        move.w  d6,(a0)+

        ; m02 = sinY*cosZ + cosY*sinX*sinZ
        move.w  d2,d6
        FPMULS14 d1,d6  ; sinY*cosZ
        move.w  d3,d7
        FPMULS14 d4,d7  ; cosY*sinX
        FPMULS14 d0,d7  ; *sinZ
        add.w   d7,d6
        move.w  d6,(a0)+

        ; m10 = cosY*sinZ + sinY*sinX*cosZ
        move.w  d3,d6
        FPMULS14 d0,d6  ; cosY*sinZ
        move.w  d2,d7
        FPMULS14 d4,d7  ; sinY*sinX
        FPMULS14 d1,d7  ; *cosZ
        add.w   d7,d6
        move.w  d6,(a0)+

        ; m11 = cosX*cosZ
        move.w  d5,d6
        FPMULS14 d1,d6
        move.w  d6,(a0)+

        ; m12 = sinY*sinZ - cosY*sinX*cosZ
        move.w  d2,d6
        FPMULS14 d0,d6  ; sinY*sinZ
        move.w  d3,d7
        FPMULS14 d4,d7  ; cosY*sinX
        FPMULS14 d1,d7  ; *cosZ
        sub.w   d7,d6
        move.w  d6,(a0)+

        ; m20 = -cosX*sinY
        move.w  d5,d6
        FPMULS14 d2,d6  ; cosX*sinY
        neg.w   d6
        move.w  d6,(a0)+

        ; m21 = sinX
        move.w  d4,(a0)+

        ; m22 = cosX*cosY
        move.w  d5,d6
        FPMULS14 d3,d6
        move.w  d6,(a0)+

        rts


********************************************************************************
; a0 - Screen buffer
;-------------------------------------------------------------------------------
Clear:
        bsr     WaitBlitter
        clr.w   bltdmod(a6)
        move.l  #$01000000,bltcon0(a6)
        move.l  a0,bltdpt(a6)
        move.w  #((SCREEN_H*BPLS)&1023)*64+SCREEN_BW/2,bltsize(a6)
        ifgt    SCREEN_H*BPLS-1024 ; remainder if max OCS height exceeded
        BLIT_WAIT
        move.w  #(SCREEN_H*BPLS-1024)*64+SCREEN_BW/2,bltsize(a6)
        endc
        rts


********************************************************************************
SwapBuffers:
;-------------------------------------------------------------------------------
        lea     ScreenBuffers(pc),a0
        movem.l (a0),d0-d1
        exg     d0,d1
        movem.l d0-d1,(a0)
; Set bpl pointers in copper
        lea     CopBplPt+2,a1
        moveq   #BPLS-1,d7
.bpll:  move.l  d1,d0
        swap    d0
        move.w  d0,(a1) ; high word of address
        move.w  d1,4(a1) ; low word of address
        addq.w  #8,a1   ; next copper instruction
        add.l   #SCREEN_BPL,d1 ; next bpl ptr
        dbf     d7,.bpll
        rts


********************************************************************************
; a0 - Screen buffer
;-------------------------------------------------------------------------------
Draw:
        bsr     WaitBlitter
        move.l  DrawScreen(pc),a0
        bsr     DrawCube
        bsr     FillScreen
        rts


********************************************************************************
DrawCube:
        bsr     InitDrawLine
          
        move.l  DrawScreen(pc),a3
        lea     Faces,a1
        lea     PointsTransformed,a2
        move.w  #FACE_COUNT-1,d7
.face
        move.w  (a1)+,d0 ; Bitplane
        lea     (a3,d0),a0

        move.w  (a1),d0 ; Vert 1
        movem.w (a2,d0),d0-d1
        move.w  2(a1),d2 ; Vert 2
        movem.w (a2,d2),d2-d3
        move.w  4(a1),d4 ; Vert 3
        movem.w (a2,d4),d4-d5

        ; Backface cull:
        ; (y1-y2)*(x2-x3)-(y2-y3)*(x1-2)
        sub.w   d2,d0   ; d0 = x1-x2
        sub.w   d4,d2   ; d2 = x2-x3
        sub.w   d3,d1   ; d1 = y1-y2
        sub.w   d5,d3   ; d5 = y2-y3
        asr.w   #4,d0
        asr.w   #4,d1
        asr.w   #4,d2
        asr.w   #4,d3
        muls    d1,d2   ; d2 = (y1-y2)*(x2-x3)
        muls    d3,d0   ; d0 = (y2-y3)*(x1-x2)
        sub.w   d2,d0   ; d0 = (y1-y2)*(x2-x3)-(y2-y3)*(x1-2)
        ble     .skip

        ; d4-d5 still ok, can we use this?

        move.w  6(a1),d0 ; Vert 3
        movem.w (a2,d0),d0-d1

        ; movem.w (POINT_COUNT-1)*4(a2),d0-d1 ; start at last vertex to close loop
        move.w  #4-1,d6
.line
        move.w  (a1)+,d2 ; Next vert
        movem.w (a2,d2),d2-d3
        BLIT_WAIT
        bsr     SubPixelBlitterEdgeLine
        move.w  d2,d0   ; end point becomes next start point
        move.w  d3,d1
        dbf     d6,.line

        dbf     d7,.face

        rts
.skip
        adda.w  #4*2,a1
        dbf     d7,.face
        rts

********************************************************************************
FillScreen:
        BLIT_WAIT

        lea     SCREEN_SIZE-2(a0),a1 ; last word of screen buffer (for descending mode)

        move.w  #ANBNC!ANBC!ABNC!ABC!DEST!SRCA,bltcon0(a6) ; bltcon0: Copy channel A -> D
        move.w  #BLITREVERSE!FILL_XOR,bltcon1(a6) ; bltcon1: Enable fill and descending mode (fill must be DESC)
        clr.l   bltamod(a6) ; Zero modulo for channels A and D (combined into single longword op)
        move.l  a1,bltapt(a6) ; Same address for source and dest
        move.l  a1,bltdpt(a6)
        move.w  #SCREEN_H*BPLS*64+SCREEN_BW/2,bltsize(a6) ; Fill whole screen
        rts


; DrawLine settings
LINE_XOR = 1            ; Use XOR minterm
LINE_ONEDOT = 1         ; Use one-dot mode for blitter fill

********************************************************************************
; Prepare common blit regs for line draw
;-------------------------------------------------------------------------------
InitDrawLine:
        BLIT_WAIT
        move.w  #SCREEN_BW,bltcmod(a6)
        move.l  #-$8000,bltbdat(a6)
        move.l  #-1,bltafwm(a6)
        rts

********************************************************************************
; Draw subpixelled blitter edge line for blitter area fill
;
; The routine assumes that the blitter is idle when called
; The routine will exit with the blitter active
;
; in	d0.w	x0 in fixed point
;	d1.w	y0 in fixed point
;	d2.w	x1 in fixed point
;	d3.w	y1 in fixed point
;	d4.w	bytes per row in bitplane
;	a0	bitplane
;	a6	$dff000
;-------------------------------------------------------------------------------
SubPixelBlitterEdgeLine:
        movem.l d2-d7/a0-a1,-(sp)

        ; move.w  d4,a1
        move.w  #SCREEN_BW,a1
		
        cmp.w   d1,d3
        bgt.s   .downward
        beq     .done
        exg     d0,d2
        exg     d1,d3
.downward
		
        cmp.w   d0,d2
        blt     .leftWard

        move.w  d2,d6
        move.w  d3,d7
		
        sub.w   d0,d2
        sub.w   d1,d3
		
        cmp.w   d2,d3
        ble     .rightWard_xMajor

.rightWard_yMajor
        move.w  #SubPixelBlitterEdgeLine_Mask,d4
        move.w  #SubPixelBlitterEdgeLine_Mask,d5
        sub.w   d0,d4
        sub.w   d1,d5
        and.w   #SubPixelBlitterEdgeLine_Mask,d4 ; prestep_x = SubPixelBlitterEdgeLine_Mask - (x0 & SubPixelBlitterEdgeLine_Mask)
        and.w   #SubPixelBlitterEdgeLine_Mask,d5 ; prestep_y = SubPixelBlitterEdgeLine_Mask - (y0 & SubPixelBlitterEdgeLine_Mask)

        asr.w   #FP_BITS,d0 ; start_x = x0 >> SubPixelBlitterEdgeLine_Bits
        asr.w   #FP_BITS,d1 ; start_y = y0 >> SubPixelBlitterEdgeLine_Bits
        subq.w  #1,d1

        neg.w   d3
		
        muls.w  d2,d5
        muls.w  d3,d4

        lsl.w   #FP_BITS,d2
        lsl.w   #FP_BITS,d3

        add.w   d5,d4   ; bltapt = dx*prestep_y-dy*prestep_x

        move.w  d2,bltbmod(a6) ; bltbmod = dx<<SubPixelBlitterEdgeLine_Bits

        add.w   d2,d3
        move.w  d3,bltamod(a6) ; bltamod = (dx-dy)<<SubPixelBlitterEdgeLine_Bits

        move.w  d4,bltapt+2(a6)
		
        asr.w   #FP_BITS,d7 ; end_y = (y1 >> SubPixelBlitterEdgeLine_Bits)
        sub.w   d1,d7   ; line_length = end_y - start_y

        move.w  #0,d6
        or.w    #BLTCON1F_SING|BLTCON1F_LINE,d6
        tst.w   d4
        bpl.s   .rightWard_yMajor_positiveGradient
        or.w    #BLTCON1F_SIGN,d6
.rightWard_yMajor_positiveGradient
        move.w  d6,bltcon1(a6)

        move.w  a1,d3
        mulu.w  d1,d3
        add.l   d3,a0
        move.w  d0,d3
        asr.w   #4,d3
        add.w   d3,d3
        add.w   d3,a0
        move.l  a0,bltcpt(a6)
        move.l  #blitter_temp_output_word,bltdpt(a6)

        move.w  d0,d2
        and.w   #$f,d2
        ror.w   #4,d2

        or.w    #BLTCON0F_USEA|BLTCON0F_USEC|BLTCON0F_USED|LINE_MINTERM,d2
        move.w  d2,bltcon0(a6)
        move.w  a1,bltcmod(a6)
        move.w  a1,bltdmod(a6)
		
        lsl.w   #6,d7
        addq.w  #2,d7
        move.w  d7,bltsize(a6)

        bra     .done

.leftWard
        move.w  d2,d6
        move.w  d3,d7
		
        sub.w   d0,d2
        sub.w   d1,d3
        neg.w   d2
		
        cmp.w   d2,d3
        ble     .leftWard_xMajor

.leftWard_yMajor
        move.w  d0,d4
        move.w  #SubPixelBlitterEdgeLine_Mask,d5
        and.w   #SubPixelBlitterEdgeLine_Mask,d4
        sub.w   d1,d5
        subq.w  #1,d4   ; prestep_x = (x0 & SubPixelBlitterEdgeLine_Mask) - 1
        and.w   #SubPixelBlitterEdgeLine_Mask,d5 ; prestep_y = SubPixelBlitterEdgeLine_Mask - (y0 & SubPixelBlitterEdgeLine_Mask)

        asr.w   #FP_BITS,d0 ; start_x = x0 >> SubPixelBlitterEdgeLine_Bits
        asr.w   #FP_BITS,d1 ; start_y = y0 >> SubPixelBlitterEdgeLine_Bits
        subq.w  #1,d1

        neg.w   d3
		
        muls.w  d2,d5
        muls.w  d3,d4

        lsl.w   #FP_BITS,d2
        lsl.w   #FP_BITS,d3

        add.w   d5,d4   ; bltapt = dx*prestep_y-dy*prestep_x

        move.w  d2,bltbmod(a6) ; bltbmod = dx<<SubPixelBlitterEdgeLine_Bits

        add.w   d2,d3
        move.w  d3,bltamod(a6) ; bltamod = (dx-dy)<<SubPixelBlitterEdgeLine_Bits

        move.w  d4,bltapt+2(a6)
		
        asr.w   #FP_BITS,d7 ; end_y = (y1 >> SubPixelBlitterEdgeLine_Bits)
        sub.w   d1,d7   ; line_length = end_y - start_y

        move.w  #BLTCON1F_SUL,d6
        or.w    #BLTCON1F_SING|BLTCON1F_LINE,d6
        tst.w   d4
        bpl.s   .leftWard_yMajor_positiveGradient
        or.w    #BLTCON1F_SIGN,d6
.leftWard_yMajor_positiveGradient
        move.w  d6,bltcon1(a6)

        move.w  a1,d3
        mulu.w  d1,d3
        add.l   d3,a0
        move.w  d0,d3
        asr.w   #4,d3
        add.w   d3,d3
        add.w   d3,a0
        move.l  a0,bltcpt(a6)
        move.l  #blitter_temp_output_word,bltdpt(a6)

        move.w  d0,d2
        and.w   #$f,d2
        ror.w   #4,d2

        or.w    #BLTCON0F_USEA|BLTCON0F_USEC|BLTCON0F_USED|LINE_MINTERM,d2
        move.w  d2,bltcon0(a6)

        move.w  a1,bltcmod(a6)
        move.w  a1,bltdmod(a6)
		
        lsl.w   #6,d7
        addq.w  #2,d7
        move.w  d7,bltsize(a6)

        bra     .done
        nop

.rightWard_xMajor
        move.w  #SubPixelBlitterEdgeLine_Mask,d4
        move.w  #SubPixelBlitterEdgeLine_Mask,d5
        sub.w   d0,d4
        sub.w   d1,d5
        and.w   #SubPixelBlitterEdgeLine_Mask,d4 ; prestep_x = SubPixelBlitterEdgeLine_Mask - (x0 & SubPixelBlitterEdgeLine_Mask)
        and.w   #SubPixelBlitterEdgeLine_Mask,d5 ; prestep_y = SubPixelBlitterEdgeLine_Mask - (y0 & SubPixelBlitterEdgeLine_Mask)

        asr.w   #FP_BITS,d0
        asr.w   #FP_BITS,d1

        subq.w  #1,d0   ; start_x = (x0 >> SubPixelBlitterEdgeLine_Bits) - 1
        subq.w  #1,d1   ; start_y = (y0 >> SubPixelBlitterEdgeLine_Bits) - 1
		
        neg.w   d2

        move.w  d3,-(sp)
        move.w  d2,-(sp)
		
        muls.w  d2,d5
        muls.w  d3,d4

        lsl.w   #FP_BITS,d2
        lsl.w   #FP_BITS,d3

        add.w   d5,d4   ; bltapt = dy*prestep_x - dx*prestep_y

        move.w  d3,bltbmod(a6) ; bltbmod = dy<<SubPixelBlitterEdgeLine_Bits

        add.w   d2,d3
        move.w  d3,bltamod(a6) ; bltamod = (dy-dx)<<SubPixelBlitterEdgeLine_Bits

        move.w  d4,bltapt+2(a6)

        move.w  a1,d3
        mulu.w  d1,d3
        add.l   d3,a0
        move.w  d0,d3
        asr.w   #4,d3
        add.w   d3,d3
        add.w   d3,a0
        move.l  a0,bltcpt(a6)
        move.l  #blitter_temp_output_word,bltdpt(a6)

        move.w  d0,d2
        and.w   #$f,d2
        ror.w   #4,d2

        or.w    #BLTCON0F_USEA|BLTCON0F_USEC|BLTCON0F_USED|LINE_MINTERM,d2
        move.w  d2,bltcon0(a6)
        move.w  a1,bltcmod(a6)
        move.w  a1,bltdmod(a6)
		
        move.w  d6,d2
        move.w  d7,d3
        and.w   #SubPixelBlitterEdgeLine_Mask,d2
        and.w   #SubPixelBlitterEdgeLine_Mask,d3
        subq.w  #1,d2
        subq.w  #1,d3

        muls.w  (sp)+,d3
        muls.w  (sp)+,d2
		
        move.w  d6,d7
        asr.w   #FP_BITS,d7 ; end_x = (x1 >> SubPixelBlitterEdgeLine_Bits)
        sub.w   d0,d7   ; line_length = end_x - start_x

        add.l   d2,d3
        ble.s   .rightWard_xMajor_nExtraPixel
        addq.w  #1,d7
.rightWard_xMajor_nExtraPixel

        move.w  #BLTCON1F_SUD,d6
        or.w    #BLTCON1F_SING|BLTCON1F_LINE,d6
        tst.w   d4
        bpl.s   .rightWard_xMajor_positiveGradient
        or.w    #BLTCON1F_SIGN,d6
.rightWard_xMajor_positiveGradient
        move.w  d6,bltcon1(a6)

        lsl.w   #6,d7
        addq.w  #2,d7
        move.w  d7,bltsize(a6)

        bra     .done

.leftWard_xMajor
        move.w  d0,d4
        move.w  #SubPixelBlitterEdgeLine_Mask,d5
        and.w   #SubPixelBlitterEdgeLine_Mask,d4
        sub.w   d1,d5
        subq.w  #1,d4   ; prestep_x = (x0 & SubPixelBlitterEdgeLine_Mask) - 1
        and.w   #SubPixelBlitterEdgeLine_Mask,d5 ; prestep_y = SubPixelBlitterEdgeLine_Mask - (y0 & SubPixelBlitterEdgeLine_Mask)

        asr.w   #FP_BITS,d0
        asr.w   #FP_BITS,d1

        addq.w  #1,d0   ; start_x = (x0 >> SubPixelBlitterEdgeLine_Bits) + 1
        subq.w  #1,d1   ; start_y = (y0 >> SubPixelBlitterEdgeLine_Bits) - 1
		
        neg.w   d2
		
        move.w  d3,-(sp)
        move.w  d2,-(sp)
		
        muls.w  d2,d5
        muls.w  d3,d4

        lsl.w   #FP_BITS,d2
        lsl.w   #FP_BITS,d3

        add.w   d5,d4   ; bltapt = dy*prestep_x - dx*prestep_y
		
        move.w  d3,bltbmod(a6) ; bltbmod = dy<<SubPixelBlitterEdgeLine_Bits

        add.w   d2,d3
        move.w  d3,bltamod(a6) ; bltamod = (dy-dx)<<SubPixelBlitterEdgeLine_Bits

        move.w  d4,bltapt+2(a6)
		
        move.w  a1,d3
        mulu.w  d1,d3
        add.l   d3,a0
        move.w  d0,d3
        asr.w   #4,d3
        add.w   d3,d3
        add.w   d3,a0
        move.l  a0,bltcpt(a6)
        move.l  #blitter_temp_output_word,bltdpt(a6)

        move.w  d0,d2
        and.w   #$f,d2
        ror.w   #4,d2

        or.w    #BLTCON0F_USEA|BLTCON0F_USEC|BLTCON0F_USED|LINE_MINTERM,d2
        move.w  d2,bltcon0(a6)

        move.w  #SubPixelBlitterEdgeLine_Mask,d2
        sub.w   d6,d2
        move.w  d7,d3
        and.w   #SubPixelBlitterEdgeLine_Mask,d2
        and.w   #SubPixelBlitterEdgeLine_Mask,d3
        subq.w  #1,d3

        muls.w  (sp)+,d3
        muls.w  (sp)+,d2
		
        move.w  d6,d7
        asr.w   #FP_BITS,d7 ; end_x = (x1 >> SubPixelBlitterEdgeLine_Bits)
        sub.w   d0,d7
        neg.w   d7      ; line_length = start_x - end_x

        add.l   d2,d3
        ble.s   .leftWard_xMajor_nExtraPixel
        addq.w  #1,d7
.leftWard_xMajor_nExtraPixel

        move.w  #BLTCON1F_SUD|BLTCON1F_AUL,d6
        or.w    #BLTCON1F_SING|BLTCON1F_LINE,d6
        tst.w   d4
        bpl.s   .leftWard_xMajor_positiveGradient
        or.w    #BLTCON1F_SIGN,d6
.leftWard_xMajor_positiveGradient
        move.w  d6,bltcon1(a6)

        move.w  a1,bltcmod(a6)
        move.w  a1,bltdmod(a6)
		
        lsl.w   #6,d7
        addq.w  #2,d7
        move.w  d7,bltsize(a6)

        bra     .done

.done
        movem.l (sp)+,d2-d7/a0-a1
        rts

********************************************************************************
Vars:
********************************************************************************

Rot:
ZRot:   dc.w    0
YRot:   dc.w    0
XRot:   dc.w    0

Frame:  dc.w    0
ScreenBuffers:
DrawScreen: dc.l Screen1
ViewScreen: dc.l Screen2

Matrix: ds.w    9       ; 3x3 rotation matrix (m00-m22)

********************************************************************************
;               data
********************************************************************************


Points:
        dc.w    CUBE_SIZE,CUBE_SIZE,CUBE_SIZE
        dc.w    CUBE_SIZE,-CUBE_SIZE,CUBE_SIZE
        dc.w    -CUBE_SIZE,-CUBE_SIZE,CUBE_SIZE
        dc.w    -CUBE_SIZE,CUBE_SIZE,CUBE_SIZE
        dc.w    CUBE_SIZE,CUBE_SIZE,-CUBE_SIZE
        dc.w    CUBE_SIZE,-CUBE_SIZE,-CUBE_SIZE
        dc.w    -CUBE_SIZE,-CUBE_SIZE,-CUBE_SIZE
        dc.w    -CUBE_SIZE,CUBE_SIZE,-CUBE_SIZE


; Bitplane index, vert indices
FACE    macro
        dc.w    \1*SCREEN_BPL,\2*4,\3*4,\4*4,\5*4
        endm

Faces:
        FACE    2,1,2,3,0
        FACE    1,3,2,6,7
        FACE    2,6,5,4,7
        FACE    1,4,5,1,0
        FACE    0,1,5,6,2
        FACE    0,4,0,3,7

        include "includes/sin.i"


*******************************************************************************
        data_c
*******************************************************************************

Cop:
        dc.w    fmode,0
        dc.w    diwstrt,DIW_YSTRT<<8!DIW_XSTRT
        dc.w    diwstop,(DIW_YSTOP&$ff)<<8!(DIW_XSTOP&$ff)
        dc.w    ddfstrt,(DIW_XSTRT-17)>>1&$fc+HIRES*4
        dc.w    ddfstop,(DIW_XSTRT-17+(DIW_LW>>4-1)<<4)>>1&$fc-SCROLL*8
        dc.w    bpl1mod,DIW_MOD
        dc.w    bpl2mod,DIW_MOD
        dc.w    bplcon0,(HIRES<<15)!(BPLS<<12)!(HAM<<11)!(DPF<<10)!(1<<9)!(LACE<<1)
        dc.w    bplcon2,PF1P!(PF2P<<3)!(PF2PRI<<6)
        dc.w    bplcon1,0
CopBplPt:
        rept    BPLS*2
        dc.w    bplpt+REPTN*2,0
        endr
CopSprPt:
        rept    8*2
        dc.w    sprpt+REPTN*2,0
        endr
CopPal:
        dc.w    color00,$000
        dc.w    color01,$f00
        dc.w    color02,$0f0
        dc.w    color03,$0f0
        dc.w    color04,$00f
        dc.w    color05,$00f
        dc.w    color06,$00f
        dc.w    color07,$00f
        dc.l    -2
CopE:


*******************************************************************************
        bss_c
*******************************************************************************

Screen1: ds.b   SCREEN_SIZE
Screen2: ds.b   SCREEN_SIZE

blitter_temp_output_word ds.w 1
                
*******************************************************************************
        bss
*******************************************************************************

PointsTransformed:
        ds.w    POINT_COUNT*2
