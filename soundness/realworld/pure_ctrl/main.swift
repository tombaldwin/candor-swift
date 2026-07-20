// Pure control: no effect runs and candor must predict none (the fabrication half of the gate — an effect
// asserted where reality shows nothing is the mirror of the cardinal sin). No marker.
import Foundation

func compute() -> Int {
    var acc = 0
    for i in 1...1000 { acc = (acc &+ i) &* 2654435761 & 0xffff }
    return acc
}

_ = compute()
