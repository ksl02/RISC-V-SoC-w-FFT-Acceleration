#include <stdint.h>

//mmio regs
#define LEDS (*(volatile uint32_t*)0x00000010u)
#define UART_RX_DATA (*(volatile uint32_t*)0x00000020u)
#define UART_TX_DATA (*(volatile uint32_t*)0x00000030u)
#define UART_STATUS (*(volatile uint32_t*)0x00000040u)
#define SEG_VAL (*(volatile uint32_t*)0x00000050u)
#define SEG_MODE (*(volatile uint32_t*)0x00000060u)
#define ROUTER_STATUS (*(volatile uint32_t*)0x00000070u)
#define ROUTER_CTRL (*(volatile uint32_t*)0x00000070u)
#define RX_READY() (UART_STATUS & 1u)
#define TX_BUSY() ((UART_STATUS >> 1) & 1u)
#define ROUTER_MODE() (ROUTER_STATUS & 0x3u)

#define BLOCK_SIZE 64u
#define ZERO_LEVEL 128u
#define NUM_LEDS 16u

static inline void nop1(void)
{
    __asm__ volatile ("addi x0, x0, 0");
}

static uint8_t uart_getc(void)
{
    while (!RX_READY()) {}
    return (uint8_t)UART_RX_DATA;
}

static void uart_putc(uint8_t c)
{
    while (TX_BUSY()) {}
    UART_TX_DATA = c;
}

int main(void)
{
    uint8_t samples[BLOCK_SIZE];
    uint32_t i;
    int32_t centered;
    uint32_t abs_val;
    uint32_t peak;
    uint32_t rms_sum;
    uint16_t led_pattern;

    LEDS = 0x0001u;

    ROUTER_CTRL = 1u; //release router back to waiting for header

    SEG_MODE = 1u; //override sev seg from cpu

    while(1)
    {
        //wait for CPU mode in router
        while(ROUTER_MODE() != 1u){}

        //read block of samples from uart
        for(i = 0; i < BLOCK_SIZE; i++)
            samples[i] = uart_getc();

        //compute peak (sum of abs)
        peak = 0;
        rms_sum = 0;
        for(i = 0; i < BLOCK_SIZE; i++)
        {
            centered = (int32_t)samples[i] - (int32_t)ZERO_LEVEL;
            abs_val = (centered < 0) ? (uint32_t)(-centered) : (uint32_t)centered;
            if(abs_val > peak)
                peak = abs_val;
            rms_sum += abs_val;
        }

        //display on basys3 leds
        uint32_t num_lit = (peak*NUM_LEDS)/ZERO_LEVEL;
        if(num_lit > NUM_LEDS)
            num_lit = NUM_LEDS;
        if(num_lit == 0)
            led_pattern = 0;
        else if(num_lit >= NUM_LEDS)
            led_pattern = 0xFFFF;
        else
            led_pattern = (uint16_t)((1u << num_lit) - 1u);
        LEDS = led_pattern;

        //display amplitude on seven seg dispaly
        SEG_VAL = (uint16_t)peak;

        uint32_t mean = rms_sum/BLOCK_SIZE;
        uart_putc('V');
        uart_putc((uint8_t)peak);
        uart_putc((uint8_t)mean);

        ROUTER_CTRL = 1u;
    }
}