import DepA
// a declaration in ANOTHER own module (Core24 declares no Tool24/Gear24/Pipe24, so these are DepA's)
public final class HC24 { public init() {}
    public var tool = Tool24()
    public var gear = Gear24()
    public var pipe = Pipe24() }
