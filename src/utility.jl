unPad(a::SVector{4,T}) where {T} = SVector{3,T}(a[1], a[2], a[3])
onePad(a::SVector{3,T}) where {T} = SVector{4,T}(a[1], a[2], a[3], one(T))
zeroPad(a::SVector{3,T}) where {T} = SVector{4,T}(a[1], a[2], a[3], zero(T))

function fill_with_nothing!(a)  # TODO: find more elegant way to do this
    for k = keys(a)
        a[k] = nothing
    end
    return nothing
end

function zeroWrench(frame::CartesianFrame3D, T::Type)
    return Wrench(Point3D(frame, SVector{3,T}(0.0, 0.0, 0.0)), FreeVector3D(frame, SVector{3,T}(0.0, 0.0, 0.0)))
end