#include "logging.h"
#include "network.h"

int main()
{
#ifdef ENABLE_NETWORKING
    printDebug("Connecting to network.");
    makeConnection();
#else
    #error "Network connection disabled!"
#endif
}