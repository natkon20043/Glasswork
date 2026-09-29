// MARK: - Code intelligence playground
// Open Go > Go to Definition with the caret on square below.
// Open Go > Find References on its declaration to find both uses.
// Change the last square to squ and use Go > Complete Code.
// Use Go > Check File for Problems to inspect unsaved compiler errors.

int square(int value) {
    return value * value;
}

// MARK: - Entry point
int main() {
    int answer = square(7);
    return answer;
}
