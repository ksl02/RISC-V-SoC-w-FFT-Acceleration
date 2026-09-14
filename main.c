#include <stdint.h>

//mmio regs
#define LEDS (*(volatile uint32_t*)0x00000010u)
#define UART_TX_DATA (*(volatile uint32_t*)0x00000030u)
#define UART_STATUS (*(volatile uint32_t*)0x00000040u)
#define SEG_VAL (*(volatile uint32_t*)0x00000050u)
#define SEG_MODE (*(volatile uint32_t*)0x00000060u)
#define ROUTER_STATUS (*(volatile uint32_t*)0x00000070u)
#define ROUTER_CTRL (*(volatile uint32_t*)0x00000070u)
#define FFT_ADDR (*(volatile uint32_t*)0x00000080u)
#define FFT_REAL (*(volatile uint32_t*)0x00000084u)
#define FFT_IMAG (*(volatile uint32_t*)0x00000088u)

#define TX_BUSY() ((UART_STATUS >> 1) & 1u)
#define ROUTER_MODE() (ROUTER_STATUS & 0x3u)
#define FFT_FRAME_READY() ((ROUTER_STATUS >> 3) & 1u)

#define FFT_LEN 64u
#define NUM_BANDS 16u
#define BINS_PER_BAND 2u
#define MAG_THRESHOLD 80u

//Send UART data every N frames
#define UART_EVERY 10u

static inline void nop1(void)
{
    __asm__ volatile ("addi x0, x0, 0");
}

static void uart_putc(uint8_t c)
{
    while (TX_BUSY()) {}
    UART_TX_DATA = c;
}

static void uart_put32(int32_t v)
{
    uart_putc((uint8_t)(v >> 24));
    uart_putc((uint8_t)(v >> 16));
    uart_putc((uint8_t)(v >> 8));
    uart_putc((uint8_t)(v >> 0));
}

static uint32_t bitrev6(uint32_t x)
{
    uint32_t r = 0;
    r |= (x & 1u) << 5;
    r |= ((x >> 1) & 1u) << 4;
    r |= ((x >> 2) & 1u) << 3;
    r |= ((x >> 3) & 1u) << 2;
    r |= ((x >> 4) & 1u) << 1;
    r |= ((x >> 5) & 1u);
    return r;
}

static uint32_t fast_mag(int32_t a, int32_t b)
{
    uint32_t ua = (a < 0) ? (uint32_t)(-a) : (uint32_t)a;
    uint32_t ub = (b < 0) ? (uint32_t)(-b) : (uint32_t)b;
    uint32_t hi, lo;
    if(ua > ub)
    {
        hi = ua;
        lo = ub;
    }
    else 
    {
        hi = ub; lo = ua;
    }
    return hi + (lo >> 2) + (lo >> 3);
}

int main(void)
{
    uint32_t natural_bin, bram_addr;
    int32_t re, im;
    uint32_t mags[FFT_LEN];
    uint32_t band_mag[NUM_BANDS];
    uint16_t led_pattern;
    uint32_t peak_bin, peak_mag;
    uint32_t frame_count = 0;

    LEDS = 0x0001u;

    ROUTER_CTRL = 1u;

    SEG_MODE = 1u; //override sev seg from cpu

    while(1)
    {

        while(!FFT_FRAME_READY()){}

        peak_bin = 0;
        peak_mag = 0;

        for(natural_bin = 0; natural_bin < FFT_LEN; natural_bin++)
        {
            bram_addr = bitrev6(natural_bin);
            FFT_ADDR = bram_addr;
            nop1();
            nop1();

            re = (int32_t)FFT_REAL;
            im = (int32_t)FFT_IMAG;
            mags[natural_bin] = fast_mag(re, im);

            if(natural_bin > 0 && natural_bin < (FFT_LEN / 2) && mags[natural_bin] > peak_mag)
            {
                peak_mag = mags[natural_bin];
                peak_bin = natural_bin;
            }
        }

        //display bins on leds
        for(uint32_t b = 0; b < NUM_BANDS; b++)
        {
            uint32_t sum = 0;
            uint32_t start = b * BINS_PER_BAND;
            for (uint32_t j = 0; j < BINS_PER_BAND; j++)
                sum += mags[start + j];
            band_mag[b] = sum;
        }

        led_pattern = 0;
        for(uint32_t b = 0; b < NUM_BANDS; b++)
        {
            if(band_mag[b] > MAG_THRESHOLD)
                led_pattern |= (1u << b);
        }
        LEDS = led_pattern;

        //display peak pin on sevseg
        SEG_VAL = (uint16_t)peak_bin;

        //ACK frame immediately so next FFT can start ASAP */
        ROUTER_CTRL = (1u << 1);

        //Send uart data
        frame_count++;
        if(UART_EVERY > 0 && frame_count >= UART_EVERY)
        {
            frame_count = 0;
            uart_putc(0xFFu);
            uart_putc((uint8_t)FFT_LEN);
            for(natural_bin = 0; natural_bin < FFT_LEN; natural_bin++)
            {
                bram_addr = bitrev6(natural_bin);
                FFT_ADDR = bram_addr;
                nop1();
                nop1();
                re = (int32_t)FFT_REAL;
                im = (int32_t)FFT_IMAG;
                uart_put32(re);
                uart_put32(im);
            }
        }
    }
}