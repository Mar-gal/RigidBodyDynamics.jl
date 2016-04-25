function subtree_mass{T}(base::Tree{RigidBody{T}, Joint})
    if isroot(base)
        result = 0
    else
        result = base.vertexData.inertia.mass
    end
    for child in base.children
        result += subtree_mass(child)
    end
    return result
end
mass(m::Mechanism) = subtree_mass(tree(m))
mass(cache::MechanismStateCache) = subtree_mass(cache.mechanism)

function center_of_mass{C}(cache::MechanismStateCache{C}, itr)
    frame = root_body(cache.mechanism).frame
    com = Point3D(frame, zero(Vec{3, C}))
    mass = zero(C)
    for body in itr
        if !isroot(body)
            inertia = body.inertia
            com += inertia.mass * transform(cache, Point3D(inertia.frame, inertia.centerOfMass), frame)
            mass += inertia.mass
        end
    end
    com /= mass
    return com
end

center_of_mass(cache::MechanismStateCache) = center_of_mass(cache, bodies(cache.mechanism))

function geometric_jacobian{C, M}(cache::MechanismStateCache{C}, path::Path{RigidBody{M}, Joint})
    flipIfNecessary = (sign::Int64, motionSubspace::GeometricJacobian{C}) -> sign == -1 ? -motionSubspace : motionSubspace
    motionSubspaces = [flipIfNecessary(sign, motion_subspace(cache, joint))::GeometricJacobian{C} for (joint, sign) in zip(path.edgeData, path.directions)]
    return hcat(motionSubspaces...)
end

function mass_matrix{C}(cache::MechanismStateCache{C})
    nv = num_velocities(keys(cache.motionSubspaces))
    H = Array(C, nv, nv)

    for i = 2 : length(cache.mechanism.toposortedTree)
        vertex_i = cache.mechanism.toposortedTree[i]

        # Hii
        body_i = vertex_i.vertexData
        joint_i = vertex_i.edgeToParentData
        v_start_i = cache.velocityVectorStartIndices[joint_i]
        i_range = v_start_i : v_start_i + num_velocities(joint_i) - 1
        S_i = motion_subspace(cache, joint_i)
        F = crb_inertia(cache, body_i) * S_i
        H[i_range, i_range] = S_i.mat' * F.mat

        # Hji, Hij
        vertex_j = vertex_i.parent
        while (!isroot(vertex_j))
            joint_j = vertex_j.edgeToParentData
            v_start_j = cache.velocityVectorStartIndices[joint_j]
            j_range = v_start_j : v_start_j + num_velocities(joint_j) - 1
            S_j = motion_subspace(cache, joint_j)
            @assert F.frame == S_j.frame
            Hji = At_mul_B(S_j.mat, F.mat)
            H[j_range, i_range] = Hji
            H[i_range, j_range] = Hji'
            vertex_j = vertex_j.parent
        end
    end
    return H
end

function momentum_matrix(cache::MechanismStateCache)
    bodiesAndJoints = [(vertex.vertexData::RigidBody, vertex.edgeToParentData::Joint) for vertex in cache.mechanism.toposortedTree[2 : end]]
    return hcat([spatial_inertia(cache, body) * motion_subspace(cache, joint) for (body, joint) in bodiesAndJoints]...)
end

function inverse_dynamics{C, M, V}(cache::MechanismStateCache{C, M}, v̇::Dict{Joint, Vector{V}}, externalWrenches::Dict{RigidBody{M}, Wrench{V}} = Dict{RigidBody{M}, Wrench{V}}())
    vertices = cache.mechanism.toposortedTree
    T = promote_type(C, V)
    jointWrenches = Dict{RigidBody{M}, Wrench{T}}()
    sizehint!(jointWrenches, length(vertices) - 1)

    # initialize joint wrenches = net wrenches
    for i = 2 : length(vertices)
        vertex = vertices[i]
        body = vertex.vertexData
        joint = vertex.edgeToParentData
        Ṫbody = acceleration_wrt_world(cache, vertex, v̇[joint])
        I = spatial_inertia(cache, body)
        Tbody = twist_wrt_world(cache, body)
        wrench = newton_euler(I, Ṫbody, Tbody)
        if haskey(externalWrenches, body)
            wrench = wrench + externalWrenches[body]
        end
        jointWrenches[body] = wrench
    end

    # project joint wrench to find torques, update parent joint wrench
    ret = zeros(T, num_velocities(cache.mechanism))
    for i = length(vertices) : -1 : 2
        vertex = vertices[i]
        body = vertex.vertexData
        parentBody = vertex.parent.vertexData
        joint = vertex.edgeToParentData
        jointWrench = jointWrenches[body]
        S = motion_subspace(cache, joint)
        τ = joint_torque(S, jointWrench)
        vStart = cache.velocityVectorStartIndices[joint]
        ret[vStart : vStart + num_velocities(joint) - 1] = τ
        if !isroot(parentBody)
            jointWrenches[parentBody] = jointWrenches[parentBody] + jointWrench
        end
    end
    return ret
end