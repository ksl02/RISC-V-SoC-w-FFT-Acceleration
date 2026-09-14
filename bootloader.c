#define UART_RX (*(volatile unsigned *)0x20)
#define UART_ST (*(volatile unsigned *)0x40)
#define UART_TX (*(volatile unsigned *)0x30)
#define LED (*(volatile unsigned *)0x10)
#define IMEM_ADDR (*(volatile unsigned *)0xA0)
#define IMEM_DATA (*(volatile unsigned *)0xA4)
#define PC_SET (*(volatile unsigned *)0xA8)

static unsigned char uart_getc(void)
{
    while (!(UART_ST & 1)){}
    return (unsigned char)UART_RX;
}

static void uart_putc(unsigned char c)
{
    while (UART_ST & 2){}
    UART_TX = c;
}

void main(void)
{
    LED = 0xB00F;

    while (1)
    {
        while(uart_getc() != 'L'){}

        //read word count
        unsigned wc = 0;
        wc |= (unsigned)uart_getc();
        wc |= (unsigned)uart_getc() << 8;
        wc |= (unsigned)uart_getc() << 16;
        wc |= (unsigned)uart_getc() << 24;

        //entry point
        unsigned entry = 0;
        entry |= (unsigned)uart_getc();
        entry |= (unsigned)uart_getc() << 8;
        entry |= (unsigned)uart_getc() << 16;
        entry |= (unsigned)uart_getc() << 24;

        LED = wc & 0xFFFF;

        //Receive and write instruction words
        for(unsigned i = 0; i < wc; i++)
        {
            unsigned word = 0;
            word |= (unsigned)uart_getc();
            word |= (unsigned)uart_getc() << 8;
            word |= (unsigned)uart_getc() << 16;
            word |= (unsigned)uart_getc() << 24;

            IMEM_ADDR = i;
            IMEM_DATA = word;
        }

        uart_putc('K'); //ACK to UART tx

        //jump to loaded program
        PC_SET = entry;
    }
}
