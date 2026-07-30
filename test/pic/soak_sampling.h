#ifndef SOAK_SAMPLING_H
#define SOAK_SAMPLING_H

// Advance and observe one simulated millisecond at a time. Keeping the sample
// inside this loop prevents an even number of transient LED changes during a
// multi-ms switch hold from collapsing into one unchanged endpoint.
template <typename AdvanceOneMs, typename SampleOneMs>
inline bool soak_run_each_ms(unsigned ms, AdvanceOneMs advance_one_ms,
                             SampleOneMs sample_one_ms) {
    for (unsigned i = 0; i < ms; ++i) {
        if (!advance_one_ms()) return false;
        sample_one_ms();
    }
    return true;
}

#endif
