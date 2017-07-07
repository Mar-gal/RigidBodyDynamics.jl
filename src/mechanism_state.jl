const BodyDict{T} = UnsafeFastDict{Graphs.vertex_index, RigidBody{T}}
const JointDict{T} = UnsafeFastDict{Graphs.edge_index, GenericJoint{T}}

"""
$(TYPEDEF)

A `MechanismState` stores state information for an entire `Mechanism`. It
contains the joint configuration and velocity vectors ``q`` and ``v``, and
a vector of additional states ``s``. In addition, it stores cache
variables that depend on ``q`` and ``v`` and are aimed at preventing double work.

Type parameters:
* `X`: the scalar type of the ``q``, ``v``, and ``s`` vectors.
* `M`: the scalar type of the `Mechanism`
* `C`: the scalar type of the cache variables (`== promote_type(X, M)`)
"""
struct MechanismState{X<:Number, M<:Number, C<:Number, T, N}
    mechanism::Mechanism{M}
    type_sorted_tree_joints::T
    type_sorted_non_tree_joints::N
    constraint_jacobian_structure::Vector{Tuple{GenericJoint{M}, TreePath{RigidBody{M}, GenericJoint{M}}}}

    q::Vector{X} # configurations
    v::Vector{X} # velocities
    s::Vector{X} # additional state

    # joint-specific
    qs::JointDict{M, VectorSegment{X}}
    vs::JointDict{M, VectorSegment{X}}
    joint_poses::JointDict{M, Transform3DS{M}}
    joint_transforms::CacheElement{JointDict{M, Transform3DS{C}}}
    joint_twists::CacheElement{JointDict{M, Twist{C}}}
    joint_bias_accelerations::CacheElement{JointDict{M, SpatialAcceleration{C}}}
    motion_subspaces::CacheElement{JointDict{M, MotionSubspace{C}}}
    motion_subspaces_in_world::CacheElement{JointDict{M, MotionSubspace{C}}} # TODO: should this be here?
    constraint_wrench_subspaces::CacheElement{JointDict{M, WrenchSubspace{C}}}

    # body-specific
    transforms_to_root::CacheElement{BodyDict{M, Transform3DS{C}}}
    twists_wrt_world::CacheElement{BodyDict{M, Twist{C}}}
    bias_accelerations_wrt_world::CacheElement{BodyDict{M, SpatialAcceleration{C}}}
    inertias::CacheElement{BodyDict{M, SpatialInertia{C}}}
    crb_inertias::CacheElement{BodyDict{M, SpatialInertia{C}}}
    contact_states::BodyDict{M, Vector{Vector{DefaultSoftContactState{X}}}} # TODO: consider moving to separate type

    function MechanismState{X}(mechanism::Mechanism{M}) where {X, M}
        C = promote_type(X, M)

        type_sorted_tree_joints = TypeSortedCollection(Graphs.edge_index, typedjoint.(tree_joints(mechanism)))
        type_sorted_non_tree_joints = TypeSortedCollection(Graphs.edge_index, typedjoint.(non_tree_joints(mechanism)))

        q = Vector{X}(num_positions(mechanism))
        v = zeros(X, num_velocities(mechanism))
        s = zeros(X, num_additional_states(mechanism))

        # joint-specific
        qstart, vstart = 1, 1
        qs = JointDict{M, VectorSegment{X}}(j => view(q, qstart : (qstart += num_positions(j)) - 1) for j in tree_joints(mechanism))
        vs = JointDict{M, VectorSegment{X}}(j => view(v, vstart : (vstart += num_velocities(j)) - 1) for j in tree_joints(mechanism))
        joint_poses = JointDict{M, Transform3DS{M}}(j => body_fixed_frame_definition(mechanism, frame_before(j)) for j in joints(mechanism))
        joint_transforms = CacheElement(JointDict{M, Transform3DS{C}}(joints(mechanism)))
        joint_twists = CacheElement(JointDict{M, Twist{C}}(tree_joints(mechanism)))
        joint_bias_accelerations = CacheElement(JointDict{M, SpatialAcceleration{C}}(tree_joints(mechanism)))
        motion_subspaces = CacheElement(JointDict{M, MotionSubspace{C}}(tree_joints(mechanism)))
        motion_subspaces_in_world = CacheElement(JointDict{M, MotionSubspace{C}}(tree_joints(mechanism)))
        constraint_wrench_subspaces = CacheElement(JointDict{M, WrenchSubspace{C}}(non_tree_joints(mechanism)))

        # body-specific
        transforms_to_root = CacheElement(BodyDict{M, Transform3DS{C}}(bodies(mechanism)))
        twists_wrt_world = CacheElement(BodyDict{M, Twist{C}}(bodies(mechanism)))
        bias_accelerations_wrt_world = CacheElement(BodyDict{M, SpatialAcceleration{C}}(bodies(mechanism)))
        inertias = CacheElement(BodyDict{M, SpatialInertia{C}}(bodies(mechanism)))
        crb_inertias = CacheElement(BodyDict{M, SpatialInertia{C}}(bodies(mechanism)))
        contact_states = BodyDict{M, Vector{Vector{DefaultSoftContactState{C}}}}(b => Vector{Vector{DefaultSoftContactState{C}}}() for b in bodies(mechanism))
        startind = 1
        for body in bodies(mechanism), point in contact_points(body)
            model = contact_model(point)
            n = num_states(model)
            push!(contact_states[body], collect(begin
                s_part = view(s, startind : startind + n - 1)
                contact_state = SoftContactState(model, s_part, root_frame(mechanism))
                startind += n
                contact_state
            end for j = 1 : length(mechanism.environment)))
        end

        m = mechanism
        constraint_jacobian_structure = [(j, path(m, predecessor(j, m), successor(j, m))) for j in non_tree_joints(m)]

        Tree = typeof(type_sorted_tree_joints)
        NonTree = typeof(type_sorted_non_tree_joints)
        state = new{X, M, C, Tree, NonTree}(mechanism, type_sorted_tree_joints, type_sorted_non_tree_joints, constraint_jacobian_structure,
            q, v, s, qs, vs, joint_poses,
            joint_transforms, joint_twists, joint_bias_accelerations, motion_subspaces, motion_subspaces_in_world, constraint_wrench_subspaces,
            transforms_to_root, twists_wrt_world, bias_accelerations_wrt_world, inertias, crb_inertias,
            contact_states)
        zero!(state)
        state
    end
end

Base.@deprecate MechanismState(::Type{X}, mechanism::Mechanism{M}) where {X, M} MechanismState{X}(mechanism)

Base.show(io::IO, ::MechanismState{X, M, C}) where {X, M, C} = print(io, "MechanismState{$X, $M, $C, …}(…)")

"""
$(SIGNATURES)

Return the length of the joint configuration vector ``q``.
"""
num_positions(state::MechanismState) = length(state.q)

"""
$(SIGNATURES)

Return the length of the joint velocity vector ``v``.
"""
num_velocities(state::MechanismState) = length(state.v)

"""
$(SIGNATURES)

Return the length of the vector of additional states ``s`` (currently used
for stateful contact models).
"""
num_additional_states(state::MechanismState) = length(state.s)

state_vector_eltype(state::MechanismState{X, M, C}) where {X, M, C} = X
mechanism_eltype(state::MechanismState{X, M, C}) where {X, M, C} = M
cache_eltype(state::MechanismState{X, M, C}) where {X, M, C} = C

"""
$(SIGNATURES)

Return the part of the configuration vector ``q`` associated with `joint`.
"""
configuration(state::MechanismState, joint::Joint) = state.qs[joint]

"""
$(SIGNATURES)

Return the part of the velocity vector ``v`` associated with `joint`.
"""
velocity(state::MechanismState, joint::Joint) = state.vs[joint]

"""
$(SIGNATURES)

Invalidate all cache variables.
"""
function setdirty!(state::MechanismState)
    setdirty!(state.joint_transforms)
    setdirty!(state.joint_twists)
    setdirty!(state.joint_bias_accelerations)
    setdirty!(state.motion_subspaces)
    setdirty!(state.motion_subspaces_in_world)
    setdirty!(state.constraint_wrench_subspaces)
    setdirty!(state.transforms_to_root)
    setdirty!(state.twists_wrt_world)
    setdirty!(state.bias_accelerations_wrt_world)
    setdirty!(state.inertias)
    setdirty!(state.crb_inertias)
end

"""
$(SIGNATURES)

Reset all contact state variables.
"""
function reset_contact_state!(state::MechanismState)
    for states_for_body in values(state.contact_states)
        for states_for_point in states_for_body
            for contact_state in states_for_point
                reset!(contact_state)
            end
        end
    end
end

"""
$(SIGNATURES)

'Zero' the configuration vector ``q``. Invalidates cache variables.

Note that when the `Mechanism` contains e.g. quaternion-parameterized joints,
``q`` may not actually be set to all zeros; the quaternion part of the
configuration vector would be set to identity. The contract is that each of the
joint transforms should be an identity transform.
"""
function zero_configuration!(state::MechanismState)
    map_in_place!(zero_configuration!, values(state.qs), state.type_sorted_tree_joints)
    reset_contact_state!(state)
    setdirty!(state)
end

"""
$(SIGNATURES)

Zero the velocity vector ``v``. Invalidates cache variables.
"""
function zero_velocity!(state::MechanismState)
    state.v[:] = 0
    reset_contact_state!(state)
    setdirty!(state)
end

"""
$(SIGNATURES)

Zero both the configuration and velocity. Invalidates cache variables.

See [`zero_configuration!`](@ref), [`zero_velocity!`](@ref).
"""
zero!(state::MechanismState) = (zero_configuration!(state); zero_velocity!(state))

"""
$(SIGNATURES)

Randomize the configuration vector ``q``. The distribution depends on
the particular joint types present in the associated `Mechanism`. The resulting
``q`` is guaranteed to be on the `Mechanism`'s configuration manifold.
Invalidates cache variables.
"""
function rand_configuration!(state::MechanismState)
    map_in_place!(rand_configuration!, values(state.qs), state.type_sorted_tree_joints)
    reset_contact_state!(state)
    setdirty!(state)
end

"""
$(SIGNATURES)

Randomize the velocity vector ``v``.
Invalidates cache variables.
"""
function rand_velocity!(state::MechanismState)
    rand!(state.v)
    reset_contact_state!(state)
    setdirty!(state)
end

"""
$(SIGNATURES)

Randomize both the configuration and velocity.
Invalidates cache variables.
"""
Random.rand!(state::MechanismState) = begin rand_configuration!(state); rand_velocity!(state) end

"""
$(SIGNATURES)

Return the configuration vector ``q``.

Note that this returns a reference to the underlying data in `state`. The user
is responsible for calling [`setdirty!`](@ref) after modifying this vector to
ensure that dependent cache variables are invalidated.
"""
configuration(state::MechanismState) = state.q

"""
$(SIGNATURES)

Return the velocity vector ``v``.

Note that this function returns a read-write reference to a field in `state`.
The user is responsible for calling [`setdirty!`](@ref) after modifying this
vector to ensure that dependent cache variables are invalidated.
"""
velocity(state::MechanismState) = state.v

"""
$(SIGNATURES)

Return the vector of additional states ``s``.
"""
additional_state(state::MechanismState) = state.s

state_vector(state::MechanismState) = [configuration(state); velocity(state); additional_state(state)]

for fun in (:num_velocities, :num_positions)
    @eval function $fun{T}(path::TreePath{RigidBody{T}, GenericJoint{T}})
        mapreduce(it -> $fun(first(it)), +, 0, path)
    end
end

function set_path_vector!{X, M, C}(ret::AbstractVector, state::MechanismState{X, M, C}, path::TreePath, fun)
    setvectorpart! = (out, part, startind) -> begin
        n = length(part)
        n > 0 && copy!(out, startind, part, 1, n)
        startind + n
    end
    startind = 1
    for (joint, direction) in path
        startind = setvectorpart!(ret, fun(state, joint), startind)
    end
    ret
end

"""
$(SIGNATURES)

Return the part of the `Mechanism`'s configuration vector ``q`` associated with
the joints along `path`.
"""
function configuration{X, M, C}(state::MechanismState{X, M, C}, path::TreePath{RigidBody{M}, GenericJoint{M}})
    set_path_vector!(Vector{X}(num_positions(path)), state, path, configuration)
end

"""
$(SIGNATURES)

Return the part of the `Mechanism`'s velocity vector ``v`` associated with
the joints along `path`.
"""
function velocity{X, M, C}(state::MechanismState{X, M, C}, path::TreePath{RigidBody{M}, GenericJoint{M}})
    set_path_vector!(Vector{X}(num_velocities(path)), state, path, velocity)
end

"""
$(SIGNATURES)

Set the part of the configuration vector associated with `joint`.
Invalidates cache variables.
"""
function set_configuration!(state::MechanismState, joint::Joint, q::AbstractVector)
    configuration(state, joint)[:] = q
    reset_contact_state!(state)
    setdirty!(state)
end

"""
$(SIGNATURES)

Set the part of the velocity vector associated with `joint`.
Invalidates cache variables.
"""
function set_velocity!(state::MechanismState, joint::Joint, v::AbstractVector)
    velocity(state, joint)[:] = v
    reset_contact_state!(state)
    setdirty!(state)
end

"""
$(SIGNATURES)

Set the configuration vector ``q``. Invalidates cache variables.
"""
function set_configuration!(state::MechanismState, q::AbstractVector)
    copy!(state.q, q)
    setdirty!(state)
end

"""
$(SIGNATURES)

Set the velocity vector ``v``. Invalidates cache variables.
"""
function set_velocity!(state::MechanismState, v::AbstractVector)
    copy!(state.v, v)
    setdirty!(state)
end

"""
$(SIGNATURES)

Set the vector of additional states ``s``.
"""
function set_additional_state!(state::MechanismState, s::AbstractVector)
    copy!(state.s, s)
    # note: setdirty! is currently not needed because no cache variables depend on s
end

function set!(state::MechanismState, x::AbstractVector)
    nq = num_positions(state)
    nv = num_velocities(state)
    ns = num_additional_states(state)
    length(x) == nq + nv + ns || error("wrong size")
    start = 1
    @inbounds copy!(state.q, 1, x, 1, nq)
    @inbounds copy!(state.v, 1, x, start += nq, nv)
    @inbounds copy!(state.s, 1, x, start += nv, ns)
    setdirty!(state)
end


configuration_range(state::MechanismState, joint::Joint) = first(parentindexes(configuration(state, joint)))
velocity_range(state::MechanismState, joint::Joint) = first(parentindexes(velocity(state, joint)))


## Accessor functions for cached variables
abstract type CacheSafety end
struct CacheSafe <: CacheSafety end
struct CacheUnsafe <: CacheSafety end

const joint_state_cache_accessors = Symbol[]
macro joint_state_cache_accessor(fun, updatefun, field)
    push!(joint_state_cache_accessors, fun)
    quote
        # Cache-safe accessor function (calls the update function first)
        Core.@__doc__ function $(fun)(state::MechanismState, joint::Joint, cache_safety::RigidBodyDynamics.CacheSafe = RigidBodyDynamics.CacheSafe())
            $(updatefun)(state)
            $(fun)(state, joint, RigidBodyDynamics.CacheUnsafe())
        end

        # Cache-unsafe version
        @inline $(fun)(state::MechanismState, joint::Joint, cache_safety::RigidBodyDynamics.CacheUnsafe) = state.$(field).data[joint]
    end |> esc
end

"""
$(SIGNATURES)

Return the joint transform for the given joint, i.e. the transform from
`frame_after(joint)` to `frame_before(joint)`.
"""
@joint_state_cache_accessor(joint_transform, update_transforms!, joint_transforms)

"""
$(SIGNATURES)
Return the joint twist for the given joint, i.e. the twist of
`frame_after(joint)` with respect to `frame_before(joint)`, expressed in the
root frame of the mechanism.
"""
@joint_state_cache_accessor(twist, update_joint_twists!, joint_twists)

"""
$(SIGNATURES)

Return the bias acceleration across the given joint, i.e. the spatial acceleration
of `frame_after(joint)` with respect to `frame_before(joint)`, expressed in the
root frame of the mechanism when all joint accelerations are zero.
"""
@joint_state_cache_accessor(bias_acceleration, update_joint_bias_accelerations!, joint_bias_accelerations)

"""
$(SIGNATURES)

Return the motion subspace of the given joint expressed in `frame_after(joint)`.
"""
@joint_state_cache_accessor(motion_subspace, update_motion_subspaces!, motion_subspaces)

"""
$(SIGNATURES)

Return the motion subspace of the given joint expressed in the root frame of
the mechanism.
"""
@joint_state_cache_accessor(motion_subspace_in_world, update_motion_subspaces_in_world!, motion_subspaces_in_world)

"""
$(SIGNATURES)

Return the constraint wrench subspace of the given joint expressed in the frame after the joint.
"""
@joint_state_cache_accessor(constraint_wrench_subspace, update_constraint_wrench_subspaces!, constraint_wrench_subspaces)

Base.@deprecate transform(state::MechanismState, joint::Joint) joint_transform(state, joint)

const body_state_cache_accessors = Symbol[]
macro body_state_cache_accessor(fun, updatefun, field)
    push!(body_state_cache_accessors, fun)
    quote
        # Cache-safe accessor function (calls the update function first)
        Core.@__doc__ function $(fun)(state::MechanismState, body::RigidBody, cache_safety::RigidBodyDynamics.CacheSafe = RigidBodyDynamics.CacheSafe())
            $(updatefun)(state)
            $(fun)(state, body, RigidBodyDynamics.CacheUnsafe())
        end

        # Cache-unsafe version
        $(fun)(state::MechanismState, body::RigidBody, cache_safety::RigidBodyDynamics.CacheUnsafe) = state.$(field).data[body]
    end |> esc
end

"""
$(SIGNATURES)

Return the transform from `default_frame(body)` to the root frame of the
mechanism.
"""
@body_state_cache_accessor(transform_to_root, update_transforms!, transforms_to_root)

"""
$(SIGNATURES)

Return the twist of `default_frame(body)` with respect to the root frame of the
mechanism, expressed in the root frame.
"""
@body_state_cache_accessor(twist_wrt_world, update_twists_wrt_world!, twists_wrt_world)

"""
$(SIGNATURES)

Return the bias acceleration of the given body with respect to the world,
i.e. the spatial acceleration of `default_frame(body)` with respect to the
root frame of the mechanism, expressed in the root frame, when all joint
accelerations are zero.
"""
@body_state_cache_accessor(bias_acceleration, update_bias_accelerations_wrt_world!, bias_accelerations_wrt_world)

"""
$(SIGNATURES)

Return the spatial inertia of `body` expressed in the root frame of the
mechanism.
"""
@body_state_cache_accessor(spatial_inertia, update_spatial_inertias!, inertias)

"""
$(SIGNATURES)

Return the composite rigid body inertia `body` expressed in the root frame of the
mechanism.
"""
@body_state_cache_accessor(crb_inertia, update_crb_inertias!, crb_inertias)

"""
$(SIGNATURES)

Replace calls to `MechanismState` cache variable accessor functions with 'cache-unsafe' versions
that do not check whether the cache is up to date and are hence faster.

By calling this macro, the user essentially provides the guarantee that the relevant cache variables
have already been updated.
"""
macro nocachecheck(ex)
    # Add `CacheUnsafe()` as the last argument to a call if the function being called is in `funcs`
    # and the number of arguments is `num_args`
    make_cache_unsafe = (x, num_args, funcs) -> begin
        if x isa Expr && x.head == :call && length(x.args) == num_args + 1 && x.args[1] ∈ funcs
            push!(x.args, :(RigidBodyDynamics.CacheUnsafe()))
        end
        x
    end

    # search and replace
    postwalk(ex) do x
        x = make_cache_unsafe(x, 2, joint_state_cache_accessors)
        x = make_cache_unsafe(x, 2, body_state_cache_accessors)
    end |> esc
end


# Cache variable update functions
function update_transforms!(state::MechanismState)
    update_tree_joint_transforms! = (results, joints, qs) -> map!(joint_transform, values(results), joints, qs)
    update!(state.joint_transforms, update_tree_joint_transforms!, state.type_sorted_tree_joints, values(state.qs))
    setdirty!(state.joint_transforms) # hack: we're not done yet

    update_transforms_to_root! = (results, state) -> begin
        mechanism = state.mechanism
        results[root_body(mechanism)] = eye(Transform3DS{cache_eltype(state)}, root_frame(mechanism))
        @nocachecheck for joint in tree_joints(mechanism)
            body = successor(joint, mechanism)
            parentbody = predecessor(joint, mechanism)
            parent_to_root = results[parentbody]
            before_joint_to_parent = state.joint_poses[joint]
            results[body] = parent_to_root * before_joint_to_parent * joint_transform(state, joint)
        end
    end
    update!(state.transforms_to_root, update_transforms_to_root!, state)

    update_non_tree_joint_transforms! = (results, state) -> begin
        @nocachecheck for (joint, _) in state.constraint_jacobian_structure
            pred = predecessor(joint, state.mechanism)
            succ = successor(joint, state.mechanism)
            before_to_root = transform_to_root(state, pred) * frame_definition(pred, frame_before(joint)) # TODO: slow!
            after_to_root = transform_to_root(state, succ) * frame_definition(succ, frame_after(joint)) # TODO: slow!
            results[joint] = inv(before_to_root) * after_to_root
        end
    end
    update!(state.joint_transforms, update_non_tree_joint_transforms!, state)
end

function update_joint_twists!(state::MechanismState)
    f! = (results, joints, qs, vs) -> map!(joint_twist, values(results), joints, qs, vs)
    update!(state.joint_twists, f!, state.type_sorted_tree_joints, values(state.qs), values(state.vs))
end

function update_joint_bias_accelerations!(state::MechanismState)
    f! = (results, joints, qs, vs) -> map!(bias_acceleration, values(results), joints, qs, vs)
    update!(state.joint_bias_accelerations, f!, state.type_sorted_tree_joints, values(state.qs), values(state.vs))
end

function update_motion_subspaces!(state::MechanismState)
    f! = (results, joints, qs) -> map!(motion_subspace, values(results), joints, qs)
    update!(state.motion_subspaces, f!, state.type_sorted_tree_joints, values(state.qs))
end

function update_constraint_wrench_subspaces!(state::MechanismState)
    update_transforms!(state)
    f! = (results, joints, transforms) -> map!(constraint_wrench_subspace, values(results), joints, transforms)
    update!(state.constraint_wrench_subspaces, f!, state.type_sorted_non_tree_joints, values(state.joint_transforms.data))
end

function update_motion_subspaces_in_world!(state::MechanismState) # TODO: make more efficient
    update_transforms!(state)
    update_motion_subspaces!(state)
    f! = (results, state) -> begin
        mechanism = state.mechanism
        @nocachecheck for joint in tree_joints(mechanism)
            body = successor(joint, mechanism)
            parentbody = predecessor(joint, mechanism)
            parentframe = default_frame(parentbody)
            motionsubspace = change_base(motion_subspace(state, joint), parentframe)
            results[joint] = transform(motionsubspace, transform_to_root(state, body))
        end
    end
    update!(state.motion_subspaces_in_world, f!, state)
end

function update_twists_wrt_world!(state::MechanismState)
    update_transforms!(state)
    update_joint_twists!(state)
    f! = (results, state) -> begin
        mechanism = state.mechanism
        rootframe = root_frame(mechanism)
        results[root_body(mechanism)] = zero(Twist{cache_eltype(state)}, rootframe, rootframe, rootframe)
        @nocachecheck for joint in tree_joints(mechanism)
            body = successor(joint, mechanism)
            parentbody = predecessor(joint, mechanism)
            parenttwist = twist_wrt_world(state, parentbody)
            parentframe = default_frame(parentbody)
            jointtwist = change_base(twist(state, joint), parentframe) # to make frames line up
            results[body] = parenttwist + transform(jointtwist, transform_to_root(state, body))
        end
    end
    update!(state.twists_wrt_world, f!, state)
end

function update_bias_accelerations_wrt_world!(state::MechanismState) # TODO: make more efficient
    update_transforms!(state)
    update_twists_wrt_world!(state)
    update_joint_bias_accelerations!(state)
    f! = (results, state) -> begin
        mechanism = state.mechanism
        rootframe = root_frame(mechanism)
        results[root_body(mechanism)] = zero(SpatialAcceleration{cache_eltype(state)}, rootframe, rootframe, rootframe)
        @nocachecheck for joint in tree_joints(mechanism)
            body = successor(joint, mechanism)
            parentbody = predecessor(joint, mechanism)
            parentbias = results[parentbody]
            parentframe = default_frame(parentbody)
            jointbias = change_base(bias_acceleration(state, joint), parentframe) # to make frames line up

             # TODO: awkward way of doing this:
            toroot = transform_to_root(state, body)
            twistwrtworld = transform(twist_wrt_world(state, body), inv(toroot))
            jointtwist = change_base(twist(state, joint), parentframe) # to make frames line up

            jointbias = transform(jointbias, toroot, twistwrtworld, jointtwist)
            results[body] = parentbias + jointbias
        end
    end
    update!(state.bias_accelerations_wrt_world, f!, state)
end

function update_spatial_inertias!(state::MechanismState)
    update_transforms!(state)
    f! = (results, state) -> begin
        mechanism = state.mechanism
        results[root_body(mechanism)] = zero(SpatialInertia{cache_eltype(state)}, root_frame(mechanism))
        @nocachecheck for joint in tree_joints(mechanism)
            body = successor(joint, mechanism)
            results[body] = transform(spatial_inertia(body), transform_to_root(state, body))
        end
    end
    update!(state.inertias, f!, state)
end

function update_crb_inertias!(state::MechanismState)
    update_spatial_inertias!(state)
    f! = (results, state) -> begin
        mechanism = state.mechanism
        @nocachecheck for body in bodies(mechanism)
            results[body] = spatial_inertia(state, body)
        end
        joints = tree_joints(mechanism)
        for i = length(joints) : -1 : 1
            joint = joints[i]
            body = successor(joint, mechanism)
            parentbody = predecessor(joint, mechanism)
            results[parentbody] += results[body]
        end
    end
    update!(state.crb_inertias, f!, state)
end

contact_states(state::MechanismState, body::RigidBody) = state.contact_states[body]

function newton_euler(state::MechanismState, body::RigidBody, accel::SpatialAcceleration)
    inertia = spatial_inertia(state, body)
    twist = twist_wrt_world(state, body)
    newton_euler(inertia, accel, twist)
end

momentum(state::MechanismState, body::RigidBody) = spatial_inertia(state, body) * twist_wrt_world(state, body)
momentum_rate_bias(state::MechanismState, body::RigidBody) = newton_euler(state, body, bias_acceleration(state, body))
kinetic_energy(state::MechanismState, body::RigidBody) = kinetic_energy(spatial_inertia(state, body), twist_wrt_world(state, body))

function configuration_derivative!{X}(out::AbstractVector{X}, state::MechanismState{X})
    # TODO: do this without a generated function
    _configuration_derivative!(out, state.type_sorted_tree_joints, values(state.qs), values(state.vs))
end

@generated function _configuration_derivative!(q̇s, joints::TypeSortedCollection{I, D}, qs, vs) where {I, D}
    expr = Expr(:block)
    push!(expr.args, :(Base.@_inline_meta))
    for i = 1 : nfields(D)
        push!(expr.args, quote
            vec = joints.data[$i]
            for joint in vec
                index = joints.indexfun(joint)
                qjoint = qs[index]
                vjoint = vs[index]
                qrange = first(parentindexes(qjoint))
                q̇joint = fastview(q̇s, qrange)
                velocity_to_configuration_derivative!(q̇joint, joint, qjoint, vjoint)
            end
        end)
    end
    push!(expr.args, :(return nothing))
    expr
end

function configuration_derivative{X}(state::MechanismState{X})
    ret = Vector{X}(num_positions(state.mechanism))
    configuration_derivative!(ret, state)
    ret
end

function transform_to_root(state::MechanismState, frame::CartesianFrame3D)
    body = body_fixed_frame_to_body(state.mechanism, frame) # FIXME: expensive
    tf = transform_to_root(state, body)
    if tf.from != frame
        tf = tf * body_fixed_frame_definition(state.mechanism, frame) # TODO: consider caching
    end
    tf
end

@inline function non_root_body_sum(state::MechanismState, start, fun, body_itr)
    ret = start
    for body in body_itr
        if !isroot(body, state.mechanism)
            ret += fun(state, body)
        end
    end
    ret
end

function momentum(state::MechanismState, body_itr)
    T = cache_eltype(state)
    non_root_body_sum(state, zero(Momentum{T}, root_frame(state.mechanism)), momentum, body_itr)
end

function momentum_rate_bias(state::MechanismState, body_itr)
    T = cache_eltype(state)
    non_root_body_sum(state, zero(Wrench{T}, root_frame(state.mechanism)), momentum_rate_bias, body_itr)
end

function kinetic_energy(state::MechanismState, body_itr)
    T = cache_eltype(state)
    non_root_body_sum(state, zero(T), kinetic_energy, body_itr)
end

for fun in (:momentum, :momentum_rate_bias, :kinetic_energy)
    @eval $fun(state::MechanismState) = $fun(state, bodies(state.mechanism))
end

"""
$(SIGNATURES)

Return the homogeneous transform from `from` to `to`.
"""
function relative_transform(state::MechanismState, from::CartesianFrame3D, to::CartesianFrame3D)
    # TODO: check if this if-else is actually worth it
    rootframe = root_frame(state.mechanism)
    if to == rootframe
        return transform_to_root(state, from)
    elseif from == rootframe
        return inv(transform_to_root(state, to))
    else
        return inv(transform_to_root(state, to)) * transform_to_root(state, from)
    end
end

"""
$(SIGNATURES)

Return the twist of `body` with respect to `base`, expressed in the
`Mechanism`'s root frame.
"""
function relative_twist(state::MechanismState, body::RigidBody, base::RigidBody)
    # TODO: check if this if-else is actually worth it
    rootBody = root_body(state.mechanism)
    if base == rootBody
        return twist_wrt_world(state, body)
    elseif body == rootBody
        return -twist_wrt_world(state, base)
    else
        return -twist_wrt_world(state, base) + twist_wrt_world(state, body)
    end
 end

 """
 $(SIGNATURES)

 Return the twist of `bodyFrame` with respect to `baseFrame`, expressed in the
 `Mechanism`'s root frame.
 """
function relative_twist(state::MechanismState, bodyFrame::CartesianFrame3D, baseFrame::CartesianFrame3D)
    twist = relative_twist(state, body_fixed_frame_to_body(state.mechanism, bodyFrame), body_fixed_frame_to_body(state.mechanism, baseFrame))
    Twist(bodyFrame, baseFrame, twist.frame, twist.angular, twist.linear)
end

for VectorType in (:Point3D, :FreeVector3D, :Twist, :Momentum, :Wrench)
    @eval begin
        function transform(state::MechanismState, v::$VectorType, to::CartesianFrame3D)::similar_type(typeof(v), promote_type(cache_eltype(state), eltype(v)))
            # TODO: consider transforming in steps, so that computing the relative transform is not necessary
            v.frame == to ? v : transform(v, relative_transform(state, v.frame, to))
        end
    end
end

function transform(state::MechanismState, accel::SpatialAcceleration, to::CartesianFrame3D)
    accel.frame == to && return accel # nothing to be done
    oldToRoot = transform_to_root(state, accel.frame)
    rootToOld = inv(oldToRoot)
    twistOfBodyWrtBase = transform(relative_twist(state, accel.body, accel.base), rootToOld)
    twistOfOldWrtNew = transform(relative_twist(state, accel.frame, to), rootToOld)
    oldToNew = inv(transform_to_root(state, to)) * oldToRoot
    transform(accel, oldToNew, twistOfOldWrtNew, twistOfBodyWrtBase)
end

"""
$(SIGNATURES)

Compute local coordinates ``\phi`` centered around (global) configuration vector
``q_0``, as well as their time derivatives ``\\dot{\\phi}``.
""" # TODO: refer to the method that takes a joint once it's moved to its own Joints module
function local_coordinates!(ϕ::StridedVector, ϕd::StridedVector, state::MechanismState, q0::StridedVector)
    # TODO: do this without a generated function
    _local_coordinates!(ϕ, ϕd, state.type_sorted_tree_joints, q0, values(state.qs), values(state.vs))
end

@generated function _local_coordinates!(ϕ, ϕd, joints::TypeSortedCollection{I, D}, q0, qs, vs) where {I, D}
    expr = Expr(:block)
    push!(expr.args, :(Base.@_inline_meta))
    for i = 1 : nfields(D)
        push!(expr.args, quote
            vec = joints.data[$i]
            for joint in vec
                index = joints.indexfun(joint)
                qjoint = qs[index]
                vjoint = vs[index]
                qrange = first(parentindexes(qjoint))
                vrange = first(parentindexes(vjoint))
                ϕjoint = fastview(ϕ, vrange)
                ϕdjoint = fastview(ϕd, vrange)
                q0joint = fastview(q0, qrange)
                local_coordinates!(ϕjoint, ϕdjoint, joint, q0joint, qjoint, vjoint)
            end
        end)
    end
    push!(expr.args, :(return nothing))
    expr
end

"""
$(SIGNATURES)

Convert local coordinates ``\phi`` centered around ``q_0`` to (global)
configuration vector ``q``.
""" # TODO: refer to the method that takes a joint once it's moved to its own Joints module
function global_coordinates!(state::MechanismState, q0::StridedVector, ϕ::StridedVector)
    # TODO: do this without a generated function
    _global_coordinates!(values(state.qs), values(state.vs), state.type_sorted_tree_joints, q0, ϕ)
end

@generated function _global_coordinates!(qs, vs, joints::TypeSortedCollection{I, D}, q0, ϕ) where {I, D}
    expr = Expr(:block)
    push!(expr.args, :(Base.@_inline_meta))
    for i = 1 : nfields(D)
        push!(expr.args, quote
            vec = joints.data[$i]
            for joint in vec
                index = joints.indexfun(joint)
                qjoint = qs[index]
                vjoint = vs[index]
                qrange = first(parentindexes(qjoint))
                vrange = first(parentindexes(vjoint))
                q0joint = fastview(q0, qrange)
                ϕjoint = fastview(ϕ, vrange)
                global_coordinates!(qjoint, joint, q0joint, ϕjoint)
            end
        end)
    end
    push!(expr.args, :(return nothing))
    expr
end
