#include <iostream>
#include <string>

constexpr auto kVersion = "0.1.0";

int main(int argc, char* argv[]) {
    if (argc > 1) {
        const std::string arg = argv[1];
        if (arg == "--version" || arg == "-v") {
            std::cout << "app " << kVersion << '\n';
            return 0;
        }
        if (arg == "--help" || arg == "-h") {
            std::cout << "Usage: app [--version|--help]\n";
            return 0;
        }
        std::cerr << "Unknown option: " << arg << '\n';
        return 1;
    }

    std::cout << "Hello from C++ app " << kVersion << '\n';
    return 0;
}
