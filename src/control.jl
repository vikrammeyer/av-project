struct VehicleCommand
    steering_angle::Float64
    forward_force::Float64 # Rename to target_velocity or similar
    persist::Bool
    shutdown::Bool
end

function get_c()
    ret = ccall(:jl_tty_set_mode, Int32, (Ptr{Cvoid},Int32), stdin.handle, true)
    ret == 0 || error("unable to switch to raw mode")
    c = read(stdin, Char)
    ccall(:jl_tty_set_mode, Int32, (Ptr{Cvoid},Int32), stdin.handle, false)
    c
end

function keyboard_controller(socket; f_step = 1.0, s_step = π/10)

    forward_force = 0.0
    steering_angle = 0.0
    persist = true
    shutdown = false
    @info "Press 'q' at any time to terminate vehicle. Press 's' to shutdown simulator server."
    while persist && !shutdown && isopen(socket)
        key = get_c()
        if key == 'q'
            # terminate vehicle
            persist = false
        elseif key == 's'
            # shutdown server
            shutdown = true
        elseif key == 'i'
            # increase forward force
            forward_force += f_step
            @info "Target velocity: $forward_force"
        elseif key == 'k'
            # decrease forward force
            forward_force -= f_step
            @info "Target velocity: $forward_force"
        elseif key == 'j'
            # increase steering angle
            steering_angle += s_step
        elseif key == 'l'
            # decrease steering angle
            steering_angle -= s_step
        end
        cmd = VehicleCommand(steering_angle, forward_force, persist, shutdown)        
        Serialization.serialize(socket, cmd)
    end
    #close(socket) # this should be closed by sim process
end

function delete_vehicle(vis, vehicle)
    name = vehicle.graph.vertices[2].name
    path = "/meshcat/world/$name"
    delete!(vis[path])
    open(vis)
    setcameratarget!(vis, [0,0,0])
    setcameraposition!(vis, [0, -3, 1])

    nothing
end

function wheel_control!(bodyid_to_wrench, chevy, t, state::MechanismState;
        reference_velocity=0.0, k₁=-1000.0)
    q = (; w = state.q[1], x = state.q[2], y = state.q[3], z = state.q[4])
    yaw = atan(2.0*(q.y*q.z + q.w*q.x), q.w*q.w - q.x*q.x - q.y*q.y + q.z*q.z)
    forward = [cos(yaw), sin(yaw), 0]
    forward_velocity = state.v[4:6]'*forward
    drive_force = k₁ * (forward_velocity - reference_velocity)

    for i = 7:8
        bodyid = BodyID(i)
        wheel = bodies(chevy)[i]
        frame = wheel.frame_definitions[1].from
        body_to_root = transform_to_root(state, bodyid, false)
        wrench = Wrench{Float64}(frame, [0.0,0,0], [drive_force,0,0])
        bodyid_to_wrench[BodyID(i)] = transform(wrench, body_to_root)
    end
    nothing
end


function steering_control!(torques::AbstractVector, t, state::MechanismState;
        reference_angle=0.0, k₁=-6500.0, k₂=-2500.0)
    js = joints(state.mechanism)
    linkage_left = js[6]
    linkage_right = js[7]

    actual = configuration(state, linkage_left)

    torques[velocity_range(state, linkage_left)] .= k₁ * (configuration(state, linkage_left) .- reference_angle) + k₂ * velocity(state, linkage_left)
    torques[velocity_range(state, linkage_right)] .= k₁ * (configuration(state, linkage_right) .- reference_angle) + k₂ * velocity(state, linkage_right)
end

function suspension_control!(torques::AbstractVector, t, state::MechanismState; k₁=-6500.0, k₂=-2500.0, k₃ = -25000.0, k₄=-10000.0)
    js = joints(state.mechanism)
    front_axle_mount = js[2]
    rear_axle_mount = js[3]
    front_axle_roll = js[4]
    rear_axle_roll = js[5]

    torques[velocity_range(state, front_axle_mount)] .= k₁ * configuration(state, front_axle_mount) + k₂ * velocity(state, front_axle_mount)
    torques[velocity_range(state, rear_axle_mount)] .= k₁ * configuration(state, rear_axle_mount) + k₂ * velocity(state, rear_axle_mount)
    torques[velocity_range(state, front_axle_roll)] .= k₃ * configuration(state, front_axle_roll) + k₄ * velocity(state, front_axle_roll)
    torques[velocity_range(state, rear_axle_roll)] .= k₃ * configuration(state, rear_axle_roll) + k₄ * velocity(state, rear_axle_roll)
end


