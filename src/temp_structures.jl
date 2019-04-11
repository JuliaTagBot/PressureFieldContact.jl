@RigidBodyDynamics.indextype BristleID

struct Bristle
    BristleID::BristleID
    τ::Float64
    k̄::Float64
    fric_pro::Float64
    function Bristle(bristle_ID::BristleID; τ::Float64, k̄::Float64, fric_pro::Float64=2.0)
        return new(bristle_ID, τ, k̄, fric_pro)
    end
end

struct Regularized
    v_tol⁻¹::Float64
    Regularized(v_tol) = new(1 / v_tol)
end

mutable struct ContactInstructions
    id_1::MeshID
    id_2::MeshID
    mutual_compliance::Bool
    FrictionModel::Union{Regularized,Bristle}
    μ::Float64
    χ::Float64
    function ContactInstructions(id_tri::MeshID, id_tet::MeshID, mutual_compliance::Bool,
            fric_model::Union{Regularized,Bristle}; μ::Float64, χ::Float64)

        (0.0 <= μ <= 3.0) || error("mu in unexpected range.")
        return new(id_tri, id_tet, mutual_compliance, fric_model, μ, χ)
    end
end

mutable struct TempContactStruct
    is_aabb::Bool
    mechanism::Mechanism
    mesh_ids::Base.OneTo{MeshID}
    bristle_ids::Base.OneTo{BristleID}
    MeshCache::RigidBodyDynamics.CustomCollections.CacheIndexDict{MeshID,Base.OneTo{MeshID},MeshCache}
    ContactInstructions::Vector{ContactInstructions}
    function TempContactStruct(mechanism::Mechanism, is_aabb::Bool=true)
        bristle_ids = Base.OneTo(BristleID(0))
        mesh_ids = Base.OneTo(MeshID(0))
        mesh_cache = MeshCacheDict{MeshCache}(mesh_ids)
        vec_ins = Vector{ContactInstructions}()
        return new(is_aabb, mechanism, mesh_ids, bristle_ids, mesh_cache, vec_ins)
    end
end

function addMesh!(ts::TempContactStruct, mesh::MeshCache)
    mesh_ids_old = ts.mesh_ids
    mesh_ids_new = Base.OneTo(MeshID(length(ts.mesh_ids) + 1))
    mesh_cache = MeshCacheDict{MeshCache}(mesh_ids_new)
    for id = mesh_ids_old
        mesh_cache[id] = ts.MeshCache[id]
    end
    mesh_cache[mesh_ids_new[end]] = mesh
    ts.MeshCache = mesh_cache
    ts.mesh_ids = mesh_ids_new
    return nothing
end

function add_body_contact!(ts::TempContactStruct, name::String, e_mesh::eMesh,
        c_prop::Union{Nothing,ContactProperties}, i_prop::InertiaProperties;
        body_parent::Union{RigidBody{Float64},Nothing}=nothing,
        joint_type::JT=SPQuatFloating{Float64}(), dh::basic_dh=one(basic_dh{Float64})) where {JT<:JointType}

    nt = add_body!(ts, name, e_mesh, i_prop, body_parent=body_parent, joint_type=joint_type, dh=dh)
    mesh_id = add_contact!(ts, name, e_mesh, c_prop, body=nt.body)  # , dh=dh)
    return NamedTuple{(:body, :joint, :mesh_id)}((nt.body, nt.joint, mesh_id))
end

function make_eTree_obb(eM_box::eMesh{T1,T2}, c_prop::Union{Nothing,ContactProperties}) where {T1,T2}
    e_tree = eTree(eM_box, c_prop)

    if T1 != Nothing
        all_obb_tri = [fit_tri_obb(eM_box, k) for k = 1:n_tri(eM_box)]
        obb_tri = obb_tree_from_aabb(e_tree.tri, all_obb_tri)
    else
        obb_tri = nothing
    end
    if T2 != Nothing
        all_obb_tet = [fit_tet_obb(eM_box, k) for k = 1:n_tet(eM_box)]
        obb_tet = obb_tree_from_aabb(e_tree.tet, all_obb_tet)
    else
        obb_tet = nothing
    end

    return eTree(obb_tri, obb_tet, c_prop)
end

function add_contact!(ts::TempContactStruct, name::String, e_mesh::eMesh,
        c_prop::Union{Nothing,ContactProperties}; body::Union{RigidBody{Float64},Nothing}=nothing
        # ,
        # ::basic_dh=one(basic_dh{Float64})
        )

    body = return_body_never_nothing(ts.mechanism, body)
    if ts.is_aabb
        e_tree = eTree(e_mesh, c_prop)
    else
        e_tree = make_eTree_obb(e_mesh, c_prop)
    end
    mesh = MeshCache(name, e_mesh, e_tree, body)
    addMesh!(ts, mesh)
    return find_mesh_id(ts, mesh)
end

function add_body!(ts::TempContactStruct, name::String, e_mesh::eMesh, i_prop::InertiaProperties;
        body_parent::Union{RigidBody{Float64},Nothing}=nothing, joint_type::JT=SPQuatFloating{Float64}(),
        dh::basic_dh=one(basic_dh{Float64})) where {JT<:JointType}

    mesh_inertia_info = makeInertiaInfo(e_mesh, i_prop)
    return add_body_from_inertia!(ts.mechanism, name, mesh_inertia_info, joint=joint_type, body_parent=body_parent, dh=dh)
end

return_body_never_nothing(mechanism::Mechanism, body::Nothing) = root_body(mechanism)
return_body_never_nothing(mechanism::Mechanism, body::RigidBody{Float64}) = body

function add_body_from_inertia!(mechanism::Mechanism, name::String, mesh_inertia_info::MeshInertiaInfo;
        joint::JT=SPQuatFloating{Float64}(), body_parent::Union{RigidBody{Float64},Nothing}=nothing,
        dh::basic_dh{Float64}=one(basic_dh{Float64})) where {JT<:JointType}

    body_parent = return_body_never_nothing(mechanism, body_parent)
    body_child = newBodyFromInertia(name, mesh_inertia_info)
    j_parent_child, x_parent_child = outputJointTransform_ParentChild(body_parent, body_child, joint, dh)
    attach!(mechanism, body_parent, body_child, j_parent_child, joint_pose=x_parent_child)
    return NamedTuple{(:body, :joint)}((body_child, j_parent_child))
end

function add_pair_rigid_compliant_regularize!(ts::TempContactStruct, mesh_id_1::MeshID, mesh_id_2::MeshID;
        μ::Union{Nothing,Float64}=nothing, χ::Union{Nothing,Float64}=nothing, v_tol::Union{Nothing,Float64}=nothing)

    if v_tol == nothing
        @warn("unspecified v_tol replaced with 0.25")
        v_tol = 0.25
    end
    regularized = Regularized(v_tol)
    return add_pair_rigid_compliant!(ts, mesh_id_1, mesh_id_2, regularized, μ=μ, χ=χ)
end

function add_pair_rigid_compliant!(ts::TempContactStruct, mesh_id_1::MeshID, mesh_id_c::MeshID,
        friction_model::Union{Regularized,Bristle}; μ::Union{Nothing,Float64}=nothing,
        χ::Union{Nothing,Float64}=nothing)

    mesh_1 = ts.MeshCache[mesh_id_1]
    mesh_c = ts.MeshCache[mesh_id_c]
    (mesh_1 == mesh_c) && error("mesh_1 and mesh_c are the same")
    is_compliant_1 = is_compliant(mesh_1)
    is_compliant_c = is_compliant(mesh_c)
    is_compliant_1 || is_compliant_c || error("neither mesh is compliant")
    if is_compliant_1
        mesh_id_1, mesh_id_c = mesh_id_c, mesh_id_1
    end
    if μ == nothing
        @warn("unspecified μ replaced with 0.3")
        μ = 0.3
    end
    if χ == nothing
        @warn("unspecified χ replaced with 0.5")
        χ = 0.5
    end
    mutual_compliance = is_compliant_1 && is_compliant_c
    push!(ts.ContactInstructions, ContactInstructions(mesh_id_1, mesh_id_c, mutual_compliance, friction_model, μ=μ, χ=χ))
    return nothing
end

function add_pair_rigid_compliant_bristle!(ts::TempContactStruct, mesh_id_1::MeshID, mesh_id_c::MeshID;
        τ::Float64=0.05, k̄=1.0e4, fric_pro=2.0, μ::Union{Nothing,Float64}=nothing, χ::Union{Nothing,Float64}=nothing)

    isa(μ, Nothing) || (0 < μ) || error("μ cannot be 0 for bristle friction")
    bristle_id = BristleID(1 + length(ts.bristle_ids))
    bf = Bristle(bristle_id, τ=τ, k̄=k̄, fric_pro=fric_pro)
    ts.bristle_ids = Base.OneTo(bristle_id)
    return add_pair_rigid_compliant!(ts, mesh_id_1, mesh_id_c, bf, μ=μ, χ=χ)
end
